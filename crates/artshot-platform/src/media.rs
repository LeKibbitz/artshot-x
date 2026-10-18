//! FFmpeg segment recorder for Windows. Pause closes a segment; resume starts a
//! fresh one. Each input remains an independent track until export.
use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use std::{
    io::Write,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
};
/// GUI builds must not create console windows for media subprocesses.
fn native_command(program: impl AsRef<std::ffi::OsStr>) -> Command {
    let mut command = Command::new(program);
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000); // CREATE_NO_WINDOW
    }
    #[cfg(not(target_os = "windows"))]
    let _ = &mut command;
    command
}
fn stop_child(mut child: Child, timeout: std::time::Duration) -> Result<std::process::ExitStatus> {
    if let Some(status) = child.try_wait()? {
        return Ok(status);
    }
    if let Some(mut input) = child.stdin.take() {
        // A child that has already failed can close its input before wait sees it.
        let _ = input.write_all(b"q\n");
    }
    let deadline = std::time::Instant::now() + timeout;
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok(status);
        }
        if std::time::Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err(Error::Native(
                "Media capture did not finish in time; retained project files may be recoverable"
                    .into(),
            ));
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct RecordingOptions {
    pub display_id: u32,
    pub region: Option<crate::Region>,
    pub microphone: bool,
    pub system_audio: bool,
    pub camera: bool,
    pub cursor: bool,
    pub clicks: bool,
    pub keystrokes: bool,
    pub microphone_device: Option<String>,
    pub system_audio_device: Option<String>,
    pub camera_device: Option<String>,
}
/// Screen and camera are captured by FFmpeg; native WASAPI retains independent
/// default microphone and default system-output loopback tracks.
pub struct Recorder {
    ffmpeg: PathBuf,
    directory: PathBuf,
    options: RecordingOptions,
    child: Option<Child>,
    segments: Vec<PathBuf>,
    video_duration: f64,
    #[cfg(target_os = "windows")]
    system_capture: Option<crate::windows_audio::WasapiRecorder>,
    #[cfg(target_os = "windows")]
    events: Option<crate::windows_events::EventRecorder>,
    #[cfg(target_os = "windows")]
    microphone_capture: Option<crate::windows_audio::WasapiRecorder>,
}
impl Recorder {
    pub fn start(
        ffmpeg: impl AsRef<Path>,
        directory: impl AsRef<Path>,
        mut options: RecordingOptions,
    ) -> Result<Self> {
        if !cfg!(target_os = "windows") {
            return Err(Error::Native(
                "Use the ScreenCaptureKit native helper on macOS".into(),
            ));
        }
        if options.camera && options.camera_device.is_none() {
            options.camera_device = list_devices(&ffmpeg)?
                .into_iter()
                .find(|d| d.kind == "video")
                .map(|d| d.name);
            if options.camera_device.is_none() {
                return Err(Error::Native("No camera device available".into()));
            }
        }
        std::fs::create_dir_all(directory.as_ref())?;
        let mut result = Self {
            ffmpeg: ffmpeg.as_ref().into(),
            directory: directory.as_ref().into(),
            options,
            child: None,
            segments: vec![],
            video_duration: 0.,
            #[cfg(target_os = "windows")]
            system_capture: None,
            #[cfg(target_os = "windows")]
            events: None,
            #[cfg(target_os = "windows")]
            microphone_capture: None,
        };
        #[cfg(target_os = "windows")]
        {
            if result.options.system_audio {
                result.system_capture = Some(
                    crate::windows_audio::WasapiRecorder::start(
                        result.directory.join("system.wav"),
                        crate::windows_audio::AudioSource::System,
                    )
                    .map_err(Error::Native)?,
                );
            }
            if result.options.microphone {
                result.microphone_capture = Some(
                    crate::windows_audio::WasapiRecorder::start(
                        result.directory.join("microphone.wav"),
                        crate::windows_audio::AudioSource::Microphone,
                    )
                    .map_err(Error::Native)?,
                );
            }
        }
        #[cfg(target_os = "windows")]
        if result.options.clicks || result.options.keystrokes {
            let display = crate::list_displays()?
                .into_iter()
                .find(|d| d.id == result.options.display_id)
                .ok_or_else(|| Error::Native("Display unavailable".into()))?;
            let local = result.options.region.unwrap_or(crate::Region {
                x: 0,
                y: 0,
                width: display.width,
                height: display.height,
            });
            result.events = Some(crate::windows_events::EventRecorder::start(
                crate::Region {
                    x: display.x + local.x,
                    y: display.y + local.y,
                    ..local
                },
                result.options.clicks,
                result.options.keystrokes,
            ));
        }
        result.resume()?;
        Ok(result)
    }
    pub fn resume(&mut self) -> Result<()> {
        if self.child.is_some() {
            return Err(Error::Native("Already recording".into()));
        }
        let display = crate::list_displays()?
            .into_iter()
            .find(|d| d.id == self.options.display_id)
            .ok_or_else(|| Error::Native("Display unavailable".into()))?;
        let r = self.options.region.unwrap_or(crate::Region {
            x: 0,
            y: 0,
            width: display.width,
            height: display.height,
        });
        crate::validate_region(r, display.width, display.height)?;
        let path = self
            .directory
            .join(format!("segment-{:04}.mkv", self.segments.len()));
        let mut cmd = native_command(&self.ffmpeg);
        cmd.args([
            "-progress",
            "pipe:1",
            "-stats_period",
            "0.05",
            "-nostats",
            "-hide_banner",
            "-n",
            "-f",
            "gdigrab",
            "-framerate",
            "30",
            "-draw_mouse",
            if self.options.cursor { "1" } else { "0" },
            "-offset_x",
            &(display.x + r.x).to_string(),
            "-offset_y",
            &(display.y + r.y).to_string(),
            "-video_size",
            &format!("{}x{}", r.width, r.height),
            "-i",
            "desktop",
        ]);
        let audio_count = 0;
        if self.options.camera {
            cmd.args([
                "-thread_queue_size",
                "1024",
                "-f",
                "dshow",
                "-i",
                &format!("video={}", self.options.camera_device.as_ref().unwrap()),
            ]);
        }
        cmd.args(["-map", "0:v:0"]);
        for i in 1..=audio_count {
            cmd.args(["-map", &format!("{i}:a:0")]);
        }
        if self.options.camera {
            cmd.args(["-map", &format!("{}:v:0", audio_count + 1)]);
        }
        cmd.args([
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-crf",
            "20",
            "-pix_fmt",
            "yuv420p",
            "-r:v:0",
            "30",
            "-fps_mode:v:0",
            "cfr",
            "-vf",
            "pad=ceil(iw/2)*2:ceil(ih/2)*2",
            "-c:a",
            "pcm_s16le",
        ]);
        cmd.arg(&path);
        if self.options.camera {
            let preview = self.directory.join("camera-preview.jpg");
            let _ = std::fs::remove_file(&preview);
            cmd.args([
                "-map",
                "1:v:0",
                "-vf",
                "fps=5,scale=320:-2",
                "-c:v",
                "mjpeg",
                "-q:v",
                "4",
                "-update",
                "1",
                "-atomic_writing",
                "1",
                "-f",
                "image2",
            ])
            .arg(preview);
        }
        let mut child = cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()?;
        let (ready_tx, ready_rx) = std::sync::mpsc::sync_channel(1);
        let progress = child
            .stdout
            .take()
            .ok_or_else(|| Error::Native("Missing FFmpeg progress pipe".into()))?;
        std::thread::spawn(move || {
            use std::io::BufRead;
            let mut sent = false;
            let mut frames = 0_u64;
            for line in std::io::BufReader::new(progress)
                .lines()
                .map_while(std::result::Result::ok)
            {
                if let Some(count) = line
                    .strip_prefix("frame=")
                    .and_then(|v| v.trim().parse::<u64>().ok())
                {
                    frames = count;
                }
                // FFmpeg progress describes a complete block. The first output
                // is the 30fps screen track; camera JPEGs must not set its clock.
                if !sent && line.starts_with("progress=") && frames > 0 {
                    #[cfg(target_os = "windows")]
                    let anchor = crate::windows_audio::host_qpc_seconds()
                        .map(|host| (frames as f64 / 30., host));
                    #[cfg(not(target_os = "windows"))]
                    let anchor: std::result::Result<(f64, f64), String> =
                        Ok((frames as f64 / 30., 0.));
                    let _ = ready_tx.send(anchor);
                    sent = true;
                }
            }
        });
        let (segment_elapsed, host_qpc) = match ready_rx
            .recv_timeout(std::time::Duration::from_secs(15))
        {
            Ok(Ok(anchor)) => anchor,
            response => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(Error::Native(match response {Ok(Err(error))=>error,_=>"FFmpeg did not produce a screen frame within 15 seconds; check capture and camera permissions".into()}));
            }
        };
        #[cfg(not(target_os = "windows"))]
        let _ = (segment_elapsed, host_qpc);
        self.child = Some(child);
        #[cfg(target_os = "windows")]
        for audio in [&self.system_capture, &self.microphone_capture]
            .into_iter()
            .flatten()
        {
            audio
                .resume_at(self.video_duration + segment_elapsed, host_qpc)
                .map_err(Error::Native)?;
        }

        #[cfg(target_os = "windows")]
        if let Some(events) = &self.events {
            events.resume_at(self.video_duration + segment_elapsed);
        }
        self.segments.push(path);
        Ok(())
    }
    /// Detect early capture termination instead of reporting an active session.
    pub fn check_running(&mut self) -> Result<()> {
        if let Some(child) = &mut self.child {
            if let Some(status) = child.try_wait()? {
                return Err(Error::Native(format!(
                    "Screen recording exited unexpectedly: {status}"
                )));
            }
        }
        Ok(())
    }
    /// Same hardware camera input as recording. The host can poll this file
    /// through its restricted asset protocol for the live camera overlay.
    pub fn camera_preview_path(&self) -> Option<PathBuf> {
        self.options
            .camera
            .then(|| self.directory.join("camera-preview.jpg"))
    }
    pub fn pause(&mut self) -> Result<()> {
        #[cfg(target_os = "windows")]
        if let Some(events) = &self.events {
            events.pause();
        }
        #[cfg(target_os = "windows")]
        for audio in [&self.system_capture, &self.microphone_capture]
            .into_iter()
            .flatten()
        {
            audio.pause().map_err(Error::Native)?;
        }
        let child = self
            .child
            .take()
            .ok_or_else(|| Error::Native("Already paused".into()))?;
        let status = stop_child(child, std::time::Duration::from_secs(15))?;
        if !status.success() {
            return Err(Error::Native(format!("FFmpeg capture failed: {status}")));
        }
        let segment = self
            .segments
            .last()
            .ok_or_else(|| Error::Native("No captured segment".into()))?;
        let ffprobe = self.ffmpeg.with_file_name(if cfg!(target_os = "windows") {
            "ffprobe.exe"
        } else {
            "ffprobe"
        });
        self.video_duration += probe(ffprobe, segment)?.duration;
        #[cfg(target_os = "windows")]
        for audio in [&self.system_capture, &self.microphone_capture]
            .into_iter()
            .flatten()
        {
            audio
                .align_end(self.video_duration)
                .map_err(Error::Native)?;
        }
        Ok(())
    }
    pub fn stop_with_audio(mut self) -> Result<RecordingResult> {
        if self.child.is_some() {
            self.pause()?;
        }
        #[cfg(target_os = "windows")]
        {
            if let Some(mut events) = self.events.take() {
                std::fs::write(
                    self.directory.join("events.json"),
                    serde_json::to_vec(&events.finish())?,
                )?;
            }
            if let Some(audio) = self.system_capture.take() {
                audio.stop().map_err(Error::Native)?;
            }
            if let Some(audio) = self.microphone_capture.take() {
                audio.stop().map_err(Error::Native)?;
            }
        }
        Ok(RecordingResult {
            segments: std::mem::take(&mut self.segments),
            system_wav: self
                .options
                .system_audio
                .then(|| self.directory.join("system.wav")),
            microphone_wav: self
                .options
                .microphone
                .then(|| self.directory.join("microphone.wav")),
        })
    }
    pub fn stop(mut self) -> Result<Vec<PathBuf>> {
        if self.child.is_some() {
            self.pause()?;
        }
        Ok(std::mem::take(&mut self.segments))
    }
}
impl Drop for Recorder {
    fn drop(&mut self) {
        if let Some(child) = self.child.take() {
            let _ = stop_child(child, std::time::Duration::from_secs(5));
        }
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Device {
    pub name: String,
    pub kind: String,
}
pub fn list_devices(ffmpeg: impl AsRef<Path>) -> Result<Vec<Device>> {
    let output = native_command(ffmpeg.as_ref())
        .args([
            "-hide_banner",
            "-list_devices",
            "true",
            "-f",
            "dshow",
            "-i",
            "dummy",
        ])
        .output()?;
    let text = String::from_utf8_lossy(&output.stderr);
    Ok(text
        .lines()
        .filter_map(|line| {
            let kind = if line.ends_with("(video)") {
                "video"
            } else if line.ends_with("(audio)") {
                "audio"
            } else {
                return None;
            };
            let begin = line.find('"')? + 1;
            let end = line[begin..].find('"')? + begin;
            Some(Device {
                name: line[begin..end].into(),
                kind: kind.into(),
            })
        })
        .collect())
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Cut {
    pub start: f64,
    pub end: f64,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct ExportOptions {
    pub start: f64,
    pub end: Option<f64>,
    pub cuts: Vec<Cut>,
    pub system_gain: f64,
    pub microphone_gain: f64,
    pub camera: bool,
    pub clicks: bool,
    pub keys: bool,
    pub camera_shape: String,
    pub camera_size: f64,
    pub camera_zoom: f64,
    pub camera_x: f64,
    pub camera_y: f64,
}
impl Default for ExportOptions {
    fn default() -> Self {
        Self {
            start: 0.,
            end: None,
            cuts: vec![],
            system_gain: 1.,
            microphone_gain: 1.,
            camera: true,
            clicks: true,
            keys: true,
            camera_shape: "roundedRectangle".into(),
            camera_size: 0.23,
            camera_zoom: 1.,
            camera_x: 0.84,
            camera_y: 0.82,
        }
    }
}
/// Keep intervals after removing cuts, merging overlapping cuts and clipping.
pub fn kept_ranges(duration: f64, edit: &ExportOptions) -> Result<Vec<(f64, f64)>> {
    if !duration.is_finite()
        || duration <= 0.
        || !edit.start.is_finite()
        || edit.end.is_some_and(|v| !v.is_finite())
        || !edit.system_gain.is_finite()
        || !edit.microphone_gain.is_finite()
    {
        return Err(Error::Native("Invalid recording edit".into()));
    }
    let begin = edit.start.max(0.);
    let end = edit.end.unwrap_or(duration).min(duration);
    let mut cuts = edit
        .cuts
        .iter()
        .filter(|c| c.start.is_finite() && c.end.is_finite() && c.end > c.start)
        .map(|c| (c.start.max(begin), c.end.min(end)))
        .filter(|(s, e)| e > s)
        .collect::<Vec<_>>();
    cuts.sort_by(|a, b| a.0.total_cmp(&b.0));
    let mut cursor = begin;
    let mut keep = vec![];
    for (s, e) in cuts {
        if s > cursor {
            keep.push((cursor, s));
        }
        cursor = cursor.max(e);
    }
    if cursor < end {
        keep.push((cursor, end));
    }
    if keep.is_empty() {
        return Err(Error::Native("Keep at least one recording interval".into()));
    }
    Ok(keep)
}
/// Concatenate capture segments losslessly. Paths are escaped for FFmpeg's concat
/// file syntax; arguments are never passed through a shell.
pub fn concatenate(
    ffmpeg: impl AsRef<Path>,
    segments: &[PathBuf],
    destination: impl AsRef<Path>,
) -> Result<()> {
    if segments.is_empty() {
        return Err(Error::Native("No recorded segments".into()));
    }
    let list = destination.as_ref().with_extension("concat.txt");
    let ffprobe = ffmpeg
        .as_ref()
        .with_file_name(if cfg!(target_os = "windows") {
            "ffprobe.exe"
        } else {
            "ffprobe"
        });
    let mut content = String::new();
    for segment in segments {
        let duration = probe(&ffprobe, segment)?.duration;
        content.push_str(&format!(
            "file '{}'\noutpoint {duration:.9}\nduration {duration:.9}\n",
            segment
                .to_string_lossy()
                .replace('\\', "/")
                .replace('\'', "'\\''")
        ));
    }
    std::fs::write(&list, content)?;
    let status = native_command(ffmpeg.as_ref())
        .args(["-hide_banner", "-n", "-f", "concat", "-safe", "0", "-i"])
        .arg(&list)
        .args(["-map", "0", "-c", "copy"])
        .arg(destination.as_ref())
        .status()?;
    let _ = std::fs::remove_file(list);
    if !status.success() {
        return Err(Error::Native("FFmpeg segment assembly failed".into()));
    }
    Ok(())
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrackManifest {
    pub path: PathBuf,
    pub duration: f64,
    pub width: u32,
    pub height: u32,
    pub camera: bool,
    pub system_audio: bool,
    pub microphone: bool,
}
/// Export screen/camera video plus independent system/microphone audio tracks.
/// WASAPI audio can be supplied as separate synchronized WAV inputs.
pub fn export_mp4(
    ffmpeg: impl AsRef<Path>,
    recording: &TrackManifest,
    edit: &ExportOptions,
    destination: impl AsRef<Path>,
    system_wav: Option<&Path>,
    microphone_wav: Option<&Path>,
) -> Result<()> {
    let keep = kept_ranges(recording.duration, edit)?;
    if recording.width == 0 || recording.height == 0 {
        return Err(Error::Native("Invalid video dimensions".into()));
    }
    let mut cmd = native_command(ffmpeg.as_ref());
    cmd.args(["-hide_banner", "-n", "-i"]).arg(&recording.path);
    let mut next_input = 1;
    let mut audio_sources: Vec<(String, f64)> = vec![];
    let mut embedded = 0;
    for (enabled, wav, gain) in [
        (recording.system_audio, system_wav, edit.system_gain),
        (recording.microphone, microphone_wav, edit.microphone_gain),
    ] {
        if !enabled {
            continue;
        }
        if let Some(wav) = wav {
            cmd.arg("-i").arg(wav);
            audio_sources.push((format!("{next_input}:a:0"), gain));
            next_input += 1;
        } else {
            audio_sources.push((format!("0:a:{embedded}"), gain));
            embedded += 1;
        }
    }
    let camera = recording.camera && edit.camera;
    let mut filters = Vec::new();
    let mut concat = String::new();
    for (i, (begin, end)) in keep.iter().enumerate() {
        filters.push(format!(
            "[0:v:0]trim=start={begin}:end={end},setpts=PTS-STARTPTS[s{i}]"
        ));
        concat.push_str(&format!("[s{i}]"));
        if camera {
            filters.push(format!(
                "[0:v:1]trim=start={begin}:end={end},setpts=PTS-STARTPTS[c{i}]"
            ));
            concat.push_str(&format!("[c{i}]"));
        }
        for (a, (source, gain)) in audio_sources.iter().enumerate() {
            filters.push(format!("[{source}]atrim=start={begin}:end={end},asetpts=PTS-STARTPTS,volume={gain}[a{i}_{a}]"));
            concat.push_str(&format!("[a{i}_{a}]"));
        }
    }
    concat.push_str(&format!(
        "concat=n={}:v={}:a={}[screen]",
        keep.len(),
        if camera { 2 } else { 1 },
        audio_sources.len()
    ));
    if camera {
        concat.push_str("[camera]");
    }
    for a in 0..audio_sources.len() {
        concat.push_str(&format!("[audio{a}]"));
    }
    filters.push(concat);
    let effects = recorded_effects(recording, edit, &keep)?;
    let screen = if effects.is_empty() {
        "[screen]"
    } else {
        filters.push(format!("[screen]{}[effects]", effects.join(",")));
        "[effects]"
    };
    let video = if camera {
        if [
            edit.camera_size,
            edit.camera_zoom,
            edit.camera_x,
            edit.camera_y,
        ]
        .iter()
        .any(|v| !v.is_finite())
        {
            return Err(Error::Native("Invalid camera layout".into()));
        }
        let ratio = match edit.camera_shape.as_str() {
            "circle" | "square" => 1.,
            "verticalOval" => 0.75,
            _ => 4. / 3.,
        };
        let width = ((recording.width as f64 * edit.camera_size.clamp(0.12, 0.45))
            .min(recording.height as f64 * ratio) as u32
            / 2
            * 2)
        .max(2);
        let height = (width as f64 / ratio) as u32;
        let zoom = edit.camera_zoom.clamp(1., 3.);
        let zw = (width as f64 * zoom) as u32 / 2 * 2;
        let zh = (height as f64 * zoom) as u32 / 2 * 2;
        let mask=match edit.camera_shape.as_str(){"circle"|"verticalOval"=>",format=yuva420p,geq=lum='lum(X,Y)':cb='cb(X,Y)':cr='cr(X,Y)':a='if(lte(pow((X-W/2)/(W/2),2)+pow((Y-H/2)/(H/2),2),1),255,0)'".to_string(),"roundedRectangle"=>",format=yuva420p,geq=lum='lum(X,Y)':cb='cb(X,Y)':cr='cr(X,Y)':a='if(lte(pow(max(abs(X-W/2)-W/2+20,0),2)+pow(max(abs(Y-H/2)-H/2+20,0),2),400),255,0)'".into(),_=>String::new()};
        filters.push(format!("[camera]scale={zw}:{zh}:force_original_aspect_ratio=increase,crop={width}:{height}{mask}[bubble]"));
        let x = (recording.width as f64 * edit.camera_x - width as f64 / 2.)
            .clamp(0., recording.width.saturating_sub(width) as f64) as u32;
        let y = (recording.height as f64 * edit.camera_y - height as f64 / 2.)
            .clamp(0., recording.height.saturating_sub(height) as f64) as u32;
        filters.push(format!(
            "{screen}[bubble]overlay={x}:{y}:eof_action=pass[vout]"
        ));
        "[vout]"
    } else {
        screen
    };
    if audio_sources.len() > 1 {
        filters.push(format!(
            "{}amix=inputs={}:normalize=0[aout]",
            (0..audio_sources.len())
                .map(|a| format!("[audio{a}]"))
                .collect::<String>(),
            audio_sources.len()
        ));
    }
    cmd.args(["-filter_complex", &filters.join(";"), "-map", video]);
    if !audio_sources.is_empty() {
        cmd.args([
            "-map",
            if audio_sources.len() > 1 {
                "[aout]"
            } else {
                "[audio0]"
            },
        ]);
    }
    let status = cmd
        .args([
            "-c:v",
            "libx264",
            "-preset",
            "medium",
            "-crf",
            "20",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-movflags",
            "+faststart",
        ])
        .arg(destination.as_ref())
        .status()?;
    if !status.success() {
        return Err(Error::Native("FFmpeg MP4 export failed".into()));
    }
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordingResult {
    pub segments: Vec<PathBuf>,
    pub system_wav: Option<PathBuf>,
    pub microphone_wav: Option<PathBuf>,
}

pub fn probe(ffprobe: impl AsRef<Path>, path: impl AsRef<Path>) -> Result<TrackManifest> {
    let output = native_command(ffprobe.as_ref())
        .args([
            "-v",
            "error",
            "-show_streams",
            "-show_format",
            "-of",
            "json",
        ])
        .arg(path.as_ref())
        .output()?;
    if !output.status.success() {
        return Err(Error::Native(
            String::from_utf8_lossy(&output.stderr).into_owned(),
        ));
    }
    let value: serde_json::Value = serde_json::from_slice(&output.stdout)?;
    let streams = value["streams"]
        .as_array()
        .ok_or_else(|| Error::Native("No media streams".into()))?;
    let videos = streams
        .iter()
        .filter(|v| v["codec_type"] == "video")
        .collect::<Vec<_>>();
    let screen = videos
        .first()
        .ok_or_else(|| Error::Native("No video stream".into()))?;
    // Matroska records a per-track DURATION tag. Camera shutdown can outlast
    // the screen, so container duration must not drive screen/audio alignment.
    let duration = screen["duration"]
        .as_str()
        .and_then(|s| s.parse::<f64>().ok())
        .or_else(|| {
            screen["tags"]["DURATION"]
                .as_str()
                .and_then(parse_media_duration)
        })
        .or_else(|| {
            value["format"]["duration"]
                .as_str()
                .and_then(|s| s.parse::<f64>().ok())
        })
        .filter(|v| v.is_finite() && *v > 0.)
        .ok_or_else(|| Error::Native("No screen media duration".into()))?;
    Ok(TrackManifest {
        path: path.as_ref().into(),
        duration,
        width: screen["width"].as_u64().unwrap_or(0) as u32,
        height: screen["height"].as_u64().unwrap_or(0) as u32,
        camera: videos.len() > 1,
        system_audio: false,
        microphone: false,
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn effect_toggles_and_cut_mapping_are_independent() {
        let root = std::env::temp_dir().join(format!(
            "artshot-events-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("events.json"),r#"[{"time":0.5,"x":0.3,"y":0.4,"label":null},{"time":2.5,"x":null,"y":null,"label":"Ctrl+C"}]"#).unwrap();
        let recording = TrackManifest {
            path: root.join("source.mkv"),
            duration: 3.,
            width: 640,
            height: 360,
            camera: false,
            system_audio: false,
            microphone: false,
        };
        let mut edit = ExportOptions {
            clicks: false,
            keys: false,
            cuts: vec![Cut { start: 1., end: 2. }],
            ..Default::default()
        };
        let keep = kept_ranges(3., &edit).unwrap();
        assert!(recorded_effects(&recording, &edit, &keep)
            .unwrap()
            .is_empty());
        edit.clicks = true;
        let effects = recorded_effects(&recording, &edit, &keep).unwrap();
        assert_eq!(effects.len(), 1);
        assert!(effects[0].starts_with("drawbox="));
        edit.clicks = false;
        edit.keys = true;
        let effects = recorded_effects(&recording, &edit, &keep).unwrap();
        assert_eq!(effects.len(), 1);
        assert!(effects[0].contains("between(t,1.5,"));
        std::fs::remove_file(root.join("events.json")).unwrap();
        std::fs::remove_dir(root).unwrap();
    }
    #[test]
    fn overlapping_cuts_preserve_expected_ranges() {
        let edit = ExportOptions {
            start: 1.,
            end: Some(9.),
            cuts: vec![Cut { start: 2., end: 5. }, Cut { start: 4., end: 7. }],
            ..Default::default()
        };
        assert_eq!(kept_ranges(10., &edit).unwrap(), vec![(1., 2.), (7., 9.)]);
    }
    #[test]
    fn fully_cut_recording_is_rejected() {
        assert!(kept_ranges(
            3.,
            &ExportOptions {
                cuts: vec![Cut { start: 0., end: 3. }],
                ..Default::default()
            }
        )
        .is_err());
    }
}

#[derive(Debug, Deserialize)]
struct RecordedEvent {
    time: f64,
    x: Option<f64>,
    y: Option<f64>,
    label: Option<String>,
}
fn recorded_effects(
    recording: &TrackManifest,
    edit: &ExportOptions,
    keep: &[(f64, f64)],
) -> Result<Vec<String>> {
    let path = recording
        .path
        .parent()
        .unwrap_or(Path::new("."))
        .join("events.json");
    if !path.exists() {
        return Ok(vec![]);
    }
    let events: Vec<RecordedEvent> = serde_json::from_slice(&std::fs::read(path)?)?;
    let mut filters = vec![];
    for event in events {
        if !event.time.is_finite() {
            continue;
        }
        let mut output_start = 0.;
        for &(begin, end) in keep {
            if event.time >= begin && event.time < end {
                let t = output_start + event.time - begin;
                if let (true, Some(x), Some(y)) = (edit.clicks, event.x, event.y) {
                    if x.is_finite() && y.is_finite() {
                        let x = (x.clamp(0., 1.) * recording.width as f64) as i64 - 18;
                        let y = (y.clamp(0., 1.) * recording.height as f64) as i64 - 18;
                        filters.push(format!("drawbox=x={x}:y={y}:w=36:h=36:color=0xff8c32@0.85:t=3:enable='between(t,{t},{})'",(t+0.6).min(output_start+end-begin)));
                    }
                }
                if let (true, Some(label)) = (edit.keys, &event.label) {
                    // Only shortcut labels generated by the native monitor are expected.
                    let escaped = label
                        .replace('\\', "\\\\")
                        .replace(':', "\\:")
                        .replace('\'', "\\'")
                        .replace('%', "\\%");
                    filters.push(format!("drawtext=fontfile='C\\:/Windows/Fonts/segoeui.ttf':text='{escaped}':fontsize=24:fontcolor=white:box=1:boxcolor=black@0.75:boxborderw=12:x=(w-tw)/2:y=h-th-32:enable='between(t,{t},{})'",(t+1.25).min(output_start+end-begin)));
                }
                break;
            }
            output_start += end - begin;
        }
    }
    Ok(filters)
}

/// Camera preview before recording. Stop this before Recorder::start so a
/// single DirectShow session owns the hardware at any point.
pub struct CameraPreview {
    child: Option<Child>,
    pub path: PathBuf,
    pub device: String,
}
impl CameraPreview {
    pub fn start(
        ffmpeg: impl AsRef<Path>,
        directory: impl AsRef<Path>,
        device: Option<String>,
    ) -> Result<Self> {
        if !cfg!(target_os = "windows") {
            return Err(Error::Native(
                "Use macOS preview_camera native action".into(),
            ));
        }
        let device = match device {
            Some(d) => d,
            None => list_devices(&ffmpeg)?
                .into_iter()
                .find(|d| d.kind == "video")
                .map(|d| d.name)
                .ok_or_else(|| Error::Native("No camera available".into()))?,
        };
        std::fs::create_dir_all(directory.as_ref())?;
        let path = directory.as_ref().join("camera-preview.jpg");
        let _ = std::fs::remove_file(&path);
        let mut child = native_command(ffmpeg.as_ref())
            .args([
                "-hide_banner",
                "-loglevel",
                "error",
                "-f",
                "dshow",
                "-i",
                &format!("video={device}"),
                "-vf",
                "fps=5,scale=320:-2",
                "-c:v",
                "mjpeg",
                "-q:v",
                "4",
                "-update",
                "1",
                "-atomic_writing",
                "1",
                "-f",
                "image2",
            ])
            .arg(&path)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()?;
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
        while !path.exists() {
            if let Some(status) = child.try_wait()? {
                return Err(Error::Native(format!("Camera preview failed: {status}")));
            }
            if std::time::Instant::now() > deadline {
                let _ = child.kill();
                let _ = child.wait();
                return Err(Error::Native(
                    "Camera did not produce preview frames".into(),
                ));
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        Ok(Self {
            child: Some(child),
            path,
            device,
        })
    }
    pub fn stop(mut self) -> Result<()> {
        self.finish()
    }
    fn finish(&mut self) -> Result<()> {
        if let Some(child) = self.child.take() {
            stop_child(child, std::time::Duration::from_secs(5))?;
        }
        Ok(())
    }
}
impl Drop for CameraPreview {
    fn drop(&mut self) {
        let _ = self.finish();
    }
}

fn parse_media_duration(value: &str) -> Option<f64> {
    let mut parts = value.split(':');
    let hours = parts.next()?.parse::<f64>().ok()?;
    let minutes = parts.next()?.parse::<f64>().ok()?;
    let seconds = parts.next()?.parse::<f64>().ok()?;
    if parts.next().is_some() {
        return None;
    }
    let duration = hours * 3600. + minutes * 60. + seconds;
    (duration.is_finite() && duration > 0.).then_some(duration)
}
