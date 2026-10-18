//! Windows 11 shared-mode WASAPI capture. System capture uses the render
//! endpoint's native loopback; no Stereo Mix or virtual device is required.
//! Each recorder starts paused. `resume` defines the first retained sample.
use serde::Serialize;
use std::{
    fs::File,
    io::BufWriter,
    path::{Path, PathBuf},
    sync::mpsc::{self, Receiver, Sender},
    thread::{self, JoinHandle},
    time::Duration,
};
use wasapi::{AudioClient, DeviceEnumerator, Direction, SampleType, StreamMode, WaveFormat};
use windows::Win32::{
    Media::Audio::{
        IAudioCaptureClient, AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY, AUDCLNT_BUFFERFLAGS_SILENT,
        AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR,
    },
    System::Performance::{QueryPerformanceCounter, QueryPerformanceFrequency},
};
const RATE: u32 = 48_000;
const CHANNELS: u16 = 2;
#[derive(Clone, Copy, Debug)]
pub enum AudioSource {
    System,
    Microphone,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioCaptureSummary {
    pub path: PathBuf,
    pub duration: f64,
    pub sample_rate: u32,
    pub channels: u16,
    pub discontinuities: u64,
    pub start_qpc_seconds: f64,
    pub first_sample_qpc_seconds: Option<f64>,
}
struct Command {
    kind: CommandKind,
    time: f64,
    ack: Sender<Result<(), String>>,
}
enum CommandKind {
    Pause,
    Resume,
    ResumeAt { media_time: f64 },
    AlignEnd { media_time: f64 },
    Stop,
}
pub struct WasapiRecorder {
    commands: Sender<Command>,
    worker: Option<JoinHandle<Result<AudioCaptureSummary, String>>>,
}
impl WasapiRecorder {
    pub fn start(path: impl AsRef<Path>, source: AudioSource) -> Result<Self, String> {
        let path = path.as_ref().to_owned();
        let (commands, rx) = mpsc::channel();
        let (ready_tx, ready_rx) = mpsc::channel();
        let worker = thread::Builder::new()
            .name(format!("artshot-wasapi-{source:?}"))
            .spawn(move || {
                let result = capture(path, source, rx, &ready_tx);
                if let Err(error) = &result {
                    let _ = ready_tx.send(Err(error.clone()));
                }
                result
            })
            .map_err(|e| e.to_string())?;
        match ready_rx.recv() {
            Ok(Ok(())) => Ok(Self {
                commands,
                worker: Some(worker),
            }),
            Ok(Err(e)) => {
                let _ = worker.join();
                Err(e)
            }
            Err(_) => {
                let _ = worker.join();
                Err("WASAPI initialization thread ended unexpectedly".into())
            }
        }
    }
    fn command(&self, kind: CommandKind) -> Result<(), String> {
        self.command_at(kind, qpc_seconds()?)
    }
    fn command_at(&self, kind: CommandKind, time: f64) -> Result<(), String> {
        let (ack, rx) = mpsc::channel();
        self.commands
            .send(Command { kind, time, ack })
            .map_err(|_| "Audio capture thread has stopped".to_string())?;
        rx.recv()
            .map_err(|_| "Audio capture command failed: capture thread stopped".to_string())?
    }
    pub fn pause(&self) -> Result<(), String> {
        self.command(CommandKind::Pause)
    }
    pub fn resume(&self) -> Result<(), String> {
        self.command(CommandKind::Resume)
    }
    /// Align a shared QPC observation to the cumulative screen-video timeline.
    pub fn resume_at(&self, media_time: f64, host_qpc_seconds: f64) -> Result<(), String> {
        if !media_time.is_finite() || media_time < 0. || !host_qpc_seconds.is_finite() {
            return Err("Invalid synchronization anchor".into());
        }
        self.command_at(CommandKind::ResumeAt { media_time }, host_qpc_seconds)
    }
    /// Pad or trim this recording's WAV to the finalized cumulative video end.
    /// This must be called after `pause` and before the next `resume_at`.
    pub fn align_end(&self, media_time: f64) -> Result<(), String> {
        if !media_time.is_finite() || media_time < 0. {
            return Err("Invalid synchronization endpoint".into());
        }
        self.command(CommandKind::AlignEnd { media_time })
    }
    pub fn stop(mut self) -> Result<AudioCaptureSummary, String> {
        let command_result = self.command(CommandKind::Stop);
        let result = self
            .worker
            .take()
            .ok_or("Audio recorder already stopped")?
            .join()
            .map_err(|_| "Audio capture thread panicked".to_string())?;
        match result {
            Err(e) => Err(e),
            Ok(summary) => {
                command_result?;
                Ok(summary)
            }
        }
    }
}
impl Drop for WasapiRecorder {
    fn drop(&mut self) {
        if let Some(worker) = self.worker.take() {
            let _ = self.command(CommandKind::Stop);
            let _ = worker.join();
        }
    }
}
pub fn host_qpc_seconds() -> Result<f64, String> {
    qpc_seconds()
}
fn qpc_seconds() -> Result<f64, String> {
    let mut counter = 0;
    let mut frequency = 0;
    unsafe {
        QueryPerformanceCounter(&mut counter).map_err(|e| e.to_string())?;
        QueryPerformanceFrequency(&mut frequency).map_err(|e| e.to_string())?;
    }
    if frequency <= 0 {
        return Err("Invalid performance clock frequency".into());
    }
    Ok(counter as f64 / frequency as f64)
}
struct ComApartment;
impl Drop for ComApartment {
    fn drop(&mut self) {
        wasapi::deinitialize();
    }
}
struct Stream(AudioClient);
impl Drop for Stream {
    fn drop(&mut self) {
        let _ = self.0.stop_stream();
    }
}
/// Explicit host-clock to media-clock spans. Video readiness and every closed
/// video segment provide anchors; pauses never accumulate independent drift.
#[derive(Default)]
struct SampleClock {
    origin: f64,
    spans: Vec<AudioSpan>,
    pause_host: Option<f64>,
    ended_output: f64,
}
struct AudioSpan {
    host_start: f64,
    host_end: Option<f64>,
    output_start: f64,
}
impl SampleClock {
    fn new(origin: f64) -> Self {
        Self {
            origin,
            spans: vec![],
            pause_host: Some(origin),
            ended_output: 0.,
        }
    }
    fn paused(&self) -> bool {
        self.pause_host.is_some()
    }
    fn set_paused(&mut self, paused: bool, time: f64) {
        if paused == self.paused() {
            return;
        }
        let time = time
            .max(self.origin)
            .max(self.pause_host.unwrap_or(self.origin));
        if paused {
            if let Some(span) = self.spans.last_mut() {
                let end = time.max(span.host_start);
                span.host_end = Some(end);
                self.ended_output = span.output_start + end - span.host_start;
                self.pause_host = Some(end);
            }
        } else {
            let output = self.ended_output;
            let _ = self.resume_at(output, time);
        }
    }
    fn resume_at(&mut self, media_time: f64, host: f64) -> Result<(), String> {
        if !self.paused() {
            return Err("Audio is already recording".into());
        }
        if !media_time.is_finite()
            || media_time < 0.
            || !host.is_finite()
            || host < self.pause_host.unwrap_or(self.origin)
        {
            return Err("Invalid video/audio synchronization anchor".into());
        }
        self.spans.push(AudioSpan {
            host_start: host,
            host_end: None,
            output_start: media_time,
        });
        self.pause_host = None;
        Ok(())
    }
    fn align_end(&mut self, media_time: f64) -> Result<(), String> {
        if !self.paused() {
            return Err("Pause audio before aligning its endpoint".into());
        }
        if !media_time.is_finite() || media_time < 0. {
            return Err("Invalid video/audio endpoint".into());
        }
        // A late callback must never reintroduce PCM beyond the closed video.
        if let Some(span) = self.spans.last_mut() {
            let allowed_end = span.host_start + (media_time - span.output_start).max(0.);
            span.host_end = Some(span.host_end.unwrap_or(allowed_end).min(allowed_end));
        }
        self.ended_output = media_time;
        Ok(())
    }
    fn elapsed(&self, time: f64) -> f64 {
        if self.pause_host.is_some_and(|paused| time >= paused) {
            return self.ended_output;
        }
        for span in self.spans.iter().rev() {
            if time >= span.host_start {
                return span.output_start
                    + (time.min(span.host_end.unwrap_or(time)) - span.host_start).max(0.);
            }
        }
        0.
    }
    fn output_frame(&self, time: f64) -> Option<u64> {
        self.spans
            .iter()
            .rev()
            .find(|span| time >= span.host_start && span.host_end.is_none_or(|end| time < end))
            .map(|span| ((span.output_start + time - span.host_start) * RATE as f64).round() as u64)
    }
}
type Writer = hound::WavWriter<BufWriter<File>>;
struct Output {
    writer: Option<Writer>,
    path: PathBuf,
    frames: u64,
    discontinuities: u64,
    first_sample: Option<f64>,
}
impl Output {
    fn silence_until(&mut self, target: u64) -> Result<(), String> {
        if target > u32::MAX as u64 / (CHANNELS as u64 * 4) {
            return Err("Audio exceeds the WAV 4 GiB limit".into());
        }
        while self.frames < target {
            for _ in 0..CHANNELS {
                self.writer
                    .as_mut()
                    .ok_or("Audio writer unavailable")?
                    .write_sample(0f32)
                    .map_err(|e| e.to_string())?;
            }
            self.frames += 1;
        }
        Ok(())
    }
    fn align_end(&mut self, target: u64) -> Result<(), String> {
        if target >= self.frames {
            return self.silence_until(target);
        }
        self.writer
            .take()
            .ok_or("Audio writer unavailable")?
            .finalize()
            .map_err(|e| e.to_string())?;
        truncate_float_wav(&self.path, target)?;
        self.writer = Some(hound::WavWriter::append(&self.path).map_err(|e| e.to_string())?);
        self.frames = target;
        Ok(())
    }
    fn packet(&mut self, clock: &SampleClock, time: f64, samples: &[f32]) -> Result<(), String> {
        for (i, frame) in samples.chunks_exact(CHANNELS as usize).enumerate() {
            let host = time + i as f64 / RATE as f64;
            let Some(index) = clock.output_frame(host) else {
                continue;
            };
            if index < self.frames {
                continue;
            }
            self.silence_until(index)?;
            if self.frames >= u32::MAX as u64 / (CHANNELS as u64 * 4) {
                return Err("Audio exceeds the WAV 4 GiB limit".into());
            }
            for sample in frame {
                self.writer
                    .as_mut()
                    .ok_or("Audio writer unavailable")?
                    .write_sample(if sample.is_finite() { *sample } else { 0. })
                    .map_err(|e| e.to_string())?;
            }
            self.frames += 1;
            self.first_sample.get_or_insert(host);
        }
        Ok(())
    }
    fn finalize(&mut self) -> Result<(), String> {
        self.writer
            .take()
            .ok_or("Audio writer unavailable")?
            .finalize()
            .map_err(|e| e.to_string())
    }
}
/// Only called on our finalized Hound float32 stereo WAV. Locate RIFF chunks
/// rather than assuming a header length (Hound can emit WAVEFORMATEXTENSIBLE).
fn truncate_float_wav(path: &Path, frames: u64) -> Result<(), String> {
    use std::io::{Read, Seek, SeekFrom, Write};
    let bytes = frames
        .checked_mul(CHANNELS as u64 * 4)
        .filter(|n| *n <= u32::MAX as u64)
        .ok_or("Audio endpoint exceeds WAV limit")?;
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .map_err(|e| e.to_string())?;
    let length = file.metadata().map_err(|e| e.to_string())?.len();
    let mut header = [0u8; 12];
    file.read_exact(&mut header).map_err(|e| e.to_string())?;
    if &header[..4] != b"RIFF" || &header[8..] != b"WAVE" {
        return Err("Invalid audio RIFF header".into());
    }
    loop {
        let mut chunk = [0u8; 8];
        file.read_exact(&mut chunk).map_err(|e| e.to_string())?;
        let size = u32::from_le_bytes(chunk[4..8].try_into().unwrap()) as u64;
        let payload = file.stream_position().map_err(|e| e.to_string())?;
        if &chunk[..4] == b"data" {
            if bytes > size || payload + size > length {
                return Err("Invalid audio truncation endpoint".into());
            }
            let end = payload + bytes;
            let riff_size = u32::try_from(end - 8).map_err(|_| "Audio RIFF size overflow")?;
            file.seek(SeekFrom::Start(payload - 4))
                .map_err(|e| e.to_string())?;
            file.write_all(&(bytes as u32).to_le_bytes())
                .map_err(|e| e.to_string())?;
            file.seek(SeekFrom::Start(4)).map_err(|e| e.to_string())?;
            file.write_all(&riff_size.to_le_bytes())
                .map_err(|e| e.to_string())?;
            file.set_len(end).map_err(|e| e.to_string())?;
            file.sync_all().map_err(|e| e.to_string())?;
            return Ok(());
        }
        let next = payload
            .checked_add(size + (size % 2))
            .filter(|n| *n <= length)
            .ok_or("Invalid audio RIFF chunk")?;
        file.seek(SeekFrom::Start(next))
            .map_err(|e| e.to_string())?;
    }
}
fn capture(
    path: PathBuf,
    source: AudioSource,
    commands: Receiver<Command>,
    ready: &Sender<Result<(), String>>,
) -> Result<AudioCaptureSummary, String> {
    wasapi::initialize_mta().ok().map_err(|e| e.to_string())?;
    let _com = ComApartment;
    let enumerator = DeviceEnumerator::new().map_err(|e| e.to_string())?;
    let direction = match source {
        AudioSource::System => Direction::Render,
        AudioSource::Microphone => Direction::Capture,
    };
    let device = enumerator
        .get_default_device(&direction)
        .map_err(|e| format!("{source:?} default endpoint unavailable: {e}"))?;
    let mut client = device.get_iaudioclient().map_err(|e| e.to_string())?;
    let format = WaveFormat::new(
        32,
        32,
        &SampleType::Float,
        RATE as usize,
        CHANNELS as usize,
        None,
    );
    let mode = StreamMode::PollingShared {
        autoconvert: true,
        buffer_duration_hns: 200_000,
    };
    client
        .initialize_client(&format, &Direction::Capture, &mode)
        .map_err(|e| format!("Cannot initialize {source:?} WASAPI capture: {e}"))?;
    // Raw GetBuffer is deliberate: WASAPI may return a NULL pointer with SILENT;
    // the high-level read helper copies that pointer before inspecting the flag.
    let reader: IAudioCaptureClient =
        unsafe { client.as_iaudioclient().GetService() }.map_err(|e| e.to_string())?;
    let writer = hound::WavWriter::create(
        &path,
        hound::WavSpec {
            channels: CHANNELS,
            sample_rate: RATE,
            bits_per_sample: 32,
            sample_format: hound::SampleFormat::Float,
        },
    )
    .map_err(|e| e.to_string())?;
    let start = qpc_seconds()?;
    let mut clock = SampleClock::new(start);
    client.start_stream().map_err(|e| e.to_string())?;
    let stream = Stream(client);
    let mut output = Output {
        writer: Some(writer),
        path: path.clone(),
        frames: 0,
        discontinuities: 0,
        first_sample: None,
    };
    ready
        .send(Ok(()))
        .map_err(|_| "Audio initialization receiver closed".to_string())?;
    loop {
        match commands.recv_timeout(Duration::from_millis(5)) {
            Ok(command) => {
                match command.kind {
                    CommandKind::Pause => {
                        clock.set_paused(true, command.time);
                        drain(&reader, &clock, &mut output)?;
                    }
                    CommandKind::Resume => {
                        clock.set_paused(false, command.time);
                    }
                    CommandKind::ResumeAt { media_time } => {
                        clock.resume_at(media_time, command.time)?;
                        output.align_end((media_time * RATE as f64).round() as u64)?;
                    }
                    CommandKind::AlignEnd { media_time } => {
                        clock.align_end(media_time)?;
                        output.align_end((media_time * RATE as f64).round() as u64)?;
                    }
                    CommandKind::Stop => {
                        clock.set_paused(true, command.time);
                        stream.0.stop_stream().map_err(|e| e.to_string())?;
                        drain(&reader, &clock, &mut output)?;
                        output.silence_until(
                            (clock.elapsed(command.time) * RATE as f64).round() as u64,
                        )?;
                        let _ = command.ack.send(Ok(()));
                        break;
                    }
                }
                let _ = command.ack.send(Ok(()));
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
        drain(&reader, &clock, &mut output)?;
        // Endpoints may emit no loopback packets while silent. Keep time instead of
        // shortening the WAV, retaining 100 ms for delayed hardware buffers.
        if !clock.paused() {
            let safe_time = qpc_seconds()? - 0.1;
            output.silence_until((clock.elapsed(safe_time) * RATE as f64).floor() as u64)?;
        }
    }
    stream.0.stop_stream().map_err(|e| e.to_string())?;
    let duration = output.frames as f64 / RATE as f64;
    let summary = AudioCaptureSummary {
        path,
        duration,
        sample_rate: RATE,
        channels: CHANNELS,
        discontinuities: output.discontinuities,
        start_qpc_seconds: start,
        first_sample_qpc_seconds: output.first_sample,
    };
    output.finalize()?;
    Ok(summary)
}
fn drain(
    reader: &IAudioCaptureClient,
    clock: &SampleClock,
    output: &mut Output,
) -> Result<(), String> {
    while unsafe { reader.GetNextPacketSize() }.map_err(|e| e.to_string())? > 0 {
        let mut data = std::ptr::null_mut();
        let mut frames = 0;
        let mut flags = 0;
        let mut position = 0;
        let mut timestamp = 0;
        unsafe {
            reader.GetBuffer(
                &mut data,
                &mut frames,
                &mut flags,
                Some(&mut position),
                Some(&mut timestamp),
            )
        }
        .map_err(|e| e.to_string())?;
        // Release every acquired packet even when disk writing fails.
        let result = (|| {
            let silent = flags & AUDCLNT_BUFFERFLAGS_SILENT.0 as u32 != 0;
            let samples = if silent {
                vec![0.; frames as usize * CHANNELS as usize]
            } else {
                if data.is_null() {
                    return Err("WASAPI returned a NULL non-silent audio packet".into());
                }
                let bytes = unsafe {
                    std::slice::from_raw_parts(data, frames as usize * CHANNELS as usize * 4)
                };
                bytes
                    .chunks_exact(4)
                    .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
                    .collect()
            };
            let time = if flags & AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR.0 as u32 != 0 {
                output.discontinuities += 1;
                qpc_seconds()? - frames as f64 / RATE as f64
            } else {
                timestamp as f64 / 10_000_000.
            };
            if flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY.0 as u32 != 0 {
                output.discontinuities += 1;
            }
            output.packet(clock, time, &samples)
        })();
        let release = unsafe { reader.ReleaseBuffer(frames) }.map_err(|e| e.to_string());
        result?;
        release?;
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn delayed_packets_are_trimmed_by_historical_pauses() {
        let mut c = SampleClock::new(100.);
        c.set_paused(false, 101.);
        c.set_paused(true, 102.);
        c.set_paused(false, 104.);
        assert_eq!(c.output_frame(100.5), None);
        assert_eq!(c.output_frame(101.), Some(0));
        assert_eq!(c.output_frame(103.), None);
        assert_eq!(c.output_frame(104.), Some(48_000));
        assert_eq!(c.elapsed(105.), 2.);
    }
    #[test]
    fn float_packets_keep_channel_order_and_silence_gaps() {
        let path =
            std::env::temp_dir().join(format!("artshot-audio-test-{}.wav", std::process::id()));
        let writer = hound::WavWriter::create(
            &path,
            hound::WavSpec {
                channels: 2,
                sample_rate: RATE,
                bits_per_sample: 32,
                sample_format: hound::SampleFormat::Float,
            },
        )
        .unwrap();
        let mut out = Output {
            writer: Some(writer),
            path: path.clone(),
            frames: 0,
            discontinuities: 0,
            first_sample: None,
        };
        let mut clock = SampleClock::new(0.);
        clock.set_paused(false, 0.);
        out.packet(&clock, 2. / RATE as f64, &[0.25, -0.5, f32::NAN, 0.75])
            .unwrap();
        assert_eq!(out.frames, 4);
        out.finalize().unwrap();
        let samples: Vec<f32> = hound::WavReader::open(&path)
            .unwrap()
            .samples::<f32>()
            .map(Result::unwrap)
            .collect();
        assert_eq!(samples, vec![0., 0., 0., 0., 0.25, -0.5, 0., 0.75]);
        std::fs::remove_file(path).unwrap();
    }
}
#[cfg(test)]
mod synchronization_tests {
    use super::*;
    fn output(path: &Path) -> Output {
        Output {
            writer: Some(
                hound::WavWriter::create(
                    path,
                    hound::WavSpec {
                        channels: CHANNELS,
                        sample_rate: RATE,
                        bits_per_sample: 32,
                        sample_format: hound::SampleFormat::Float,
                    },
                )
                .unwrap(),
            ),
            path: path.to_owned(),
            frames: 0,
            discontinuities: 0,
            first_sample: None,
        }
    }
    #[test]
    fn video_anchor_includes_leading_time_and_rebases_each_segment() {
        let mut clock = SampleClock::new(100.);
        // Ten seconds opening a camera never become ten seconds of media.
        clock.resume_at(0.3, 110.).unwrap();
        assert_eq!(clock.output_frame(110.), Some(14_400));
        assert_eq!(clock.output_frame(109.9), None);
        clock.set_paused(true, 112.);
        clock.align_end(2.).unwrap();
        assert_eq!(clock.elapsed(119.), 2.);
        assert_eq!(clock.output_frame(111.9), None);
        // A second segment reports 0.2s of already encoded screen frames.
        clock.resume_at(2.2, 120.).unwrap();
        assert_eq!(clock.output_frame(120.), Some(105_600));
        clock.set_paused(true, 121.);
        clock.align_end(3.).unwrap();
        assert_eq!(clock.elapsed(125.), 3.);
        assert_eq!(clock.output_frame(120.9), None);
    }
    #[test]
    fn aligned_wav_truncates_reopens_and_appends_without_stale_pcm() {
        let path =
            std::env::temp_dir().join(format!("artshot-audio-align-{}.wav", std::process::id()));
        let mut out = output(&path);
        let mut clock = SampleClock::new(100.);
        clock.resume_at(2. / RATE as f64, 100.).unwrap();
        out.packet(&clock, 100., &[0.25, -0.5, 0.5, -0.25]).unwrap();
        assert_eq!(out.frames, 4);
        clock.set_paused(true, 100. + 2. / RATE as f64);
        clock.align_end(1. / RATE as f64).unwrap();
        out.align_end(1).unwrap();
        // A late callback for the previous segment cannot regrow its trimmed end.
        out.packet(&clock, 100., &[0.75, 0.75]).unwrap();
        assert_eq!(out.frames, 1);
        clock.resume_at(1. / RATE as f64, 200.).unwrap();
        out.packet(&clock, 200., &[0.9, -0.9]).unwrap();
        out.finalize().unwrap();
        let reader = hound::WavReader::open(&path).unwrap();
        assert_eq!(reader.duration(), 2);
        let samples: Vec<f32> = reader.into_samples::<f32>().map(Result::unwrap).collect();
        assert_eq!(samples, vec![0., 0., 0.9, -0.9]);
        std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn endpoint_padding_and_invalid_active_alignment() {
        let mut clock = SampleClock::new(0.);
        clock.resume_at(0., 1.).unwrap();
        assert!(clock.align_end(2.).is_err());
        assert!(!clock.paused());
        clock.set_paused(true, 2.);
        clock.align_end(1.5).unwrap();
        assert_eq!(clock.elapsed(4.), 1.5);
        assert_eq!(clock.output_frame(2.1), None);
        assert!(clock.resume_at(f64::NAN, 5.).is_err());
    }
}
