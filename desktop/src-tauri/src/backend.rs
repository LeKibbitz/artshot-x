use crate::model::*;
use artshot_core::{AppendResult, ScrollStitcher};
use artshot_platform::{Display, NativeBridge, Region};
use image::RgbaImage;
use serde_json::{json, Value};
use std::{
    fs,
    path::{Path, PathBuf},
};
use uuid::Uuid;

pub struct Backend {
    pub state: AppState,
    pub root: PathBuf,
    pub resources: PathBuf,
    pub display: Option<Display>,
    pub stitcher: Option<ScrollStitcher>,
    pub previous_frame: Option<RgbaImage>,
    pub scroll_epoch: u64,
    pub camera_preview_active: bool,
    #[cfg(target_os = "windows")]
    pub camera_preview: Option<artshot_platform::media::CameraPreview>,
    pub recording_directory: Option<PathBuf>,
    pub native: Option<NativeBridge>,
    pub clock: Option<RecordingClock>,
    pub record_options: Option<RecordingOptions>,
    #[cfg(target_os = "windows")]
    pub recorder: Option<artshot_platform::media::Recorder>,
}
impl Backend {
    pub fn new(root: PathBuf, resources: PathBuf) -> Result<Self, String> {
        fs::create_dir_all(&root).map_err(err)?;
        fs::create_dir_all(root.join("captures")).map_err(err)?;
        fs::create_dir_all(root.join("cache")).map_err(err)?;
        let mut state = AppState::default();
        if root.join("library.json").exists() {
            state.library =
                serde_json::from_slice(&fs::read(root.join("library.json")).map_err(err)?)
                    .map_err(err)?;
            state.library.retain(|i| Path::new(&i.path).exists());
        }
        if root.join("settings.json").exists() {
            state.settings =
                serde_json::from_slice(&fs::read(root.join("settings.json")).map_err(err)?)
                    .map_err(err)?;
        }
        Ok(Self {
            state,
            root,
            resources,
            display: None,
            stitcher: None,
            previous_frame: None,
            scroll_epoch: 0,
            camera_preview_active: false,
            #[cfg(target_os = "windows")]
            camera_preview: None,
            recording_directory: None,
            native: None,
            clock: None,
            record_options: None,
            #[cfg(target_os = "windows")]
            recorder: None,
        })
    }
    pub fn snapshot(&self) -> AppState {
        let mut s = self.state.clone();
        if let (Some(r), Some(clock)) = (&mut s.recording, &self.clock) {
            r.elapsed = clock.elapsed();
        }
        s
    }
    pub fn save(&self) -> Result<(), String> {
        atomic_json(&self.root.join("library.json"), &self.state.library)
    }
    pub fn bridge(&mut self) -> Result<&mut NativeBridge, String> {
        if self.native.is_none() {
            self.native =
                Some(NativeBridge::spawn(self.resources.join("bin/artshot-native")).map_err(err)?);
        }
        Ok(self.native.as_mut().unwrap())
    }
    pub fn item(&self, id: &str) -> Result<MediaItem, String> {
        self.state
            .library
            .iter()
            .find(|i| i.id == id)
            .cloned()
            .ok_or_else(|| "Capture introuvable".into())
    }
    pub fn target(&self) -> Result<(Display, Option<Region>), String> {
        let d = self.display.clone().ok_or("Sélectionnez un écran")?;
        let r = self.state.selection.map(|r| r.region(&d)).transpose()?;
        Ok((d, r))
    }
    pub fn frame(
        &mut self,
        display: &Display,
        region: Option<Region>,
    ) -> Result<RgbaImage, String> {
        #[cfg(target_os = "macos")]
        {
            let path = self.root.join("cache/frame.png");
            self.bridge()?
                .capture_png(display.id, region, &path, std::process::id())
                .map_err(err)?;
            Ok(image::open(path).map_err(err)?.into_rgba8())
        }
        #[cfg(not(target_os = "macos"))]
        {
            artshot_platform::capture(display.id, region).map_err(err)
        }
    }
    pub fn add_image(&mut self, image: RgbaImage) -> Result<MediaItem, String> {
        let id = Uuid::new_v4().to_string();
        let path = self.root.join("captures").join(format!("{id}.png"));
        image.save(&path).map_err(err)?;
        let item = MediaItem {
            id,
            name: format!("Capture {}", chrono::Local::now().format("%d-%m %H.%M.%S")),
            kind: "image".into(),
            path: path.to_string_lossy().into(),
            created_at: chrono::Utc::now().to_rfc3339(),
            width: image.width(),
            height: image.height(),
            duration: None,
            original_path: None,
            recording_options: Value::Null,
            system_wav: None,
            microphone_wav: None,
        };
        let mut library = self.state.library.clone();
        library.insert(0, item.clone());
        atomic_json(&self.root.join("library.json"), &library)?;
        self.state.active_item_id = Some(item.id.clone());
        self.state.library = library;
        Ok(item)
    }
    pub fn prepare(&mut self, d: Display, mode: String) -> Result<(), String> {
        self.ensure_idle()?;
        let frame = self.frame(&d, None)?;
        let path = self.root.join("cache/selection.png");
        frame.save(&path).map_err(err)?;
        self.state.selection = None;
        self.state.selection_mode = mode;
        self.state.selection_display = Some(SelectionDisplay {
            id: d.id.to_string(),
            width: d.width,
            height: d.height,
            scale_factor: d.scale_factor,
            background_path: path.to_string_lossy().into(),
        });
        self.display = Some(d);
        self.state.error = None;
        Ok(())
    }
    pub fn ensure_idle(&self) -> Result<(), String> {
        if self.state.recording.is_some() || self.stitcher.is_some() {
            Err("Terminez d’abord la capture en cours".into())
        } else {
            Ok(())
        }
    }
    pub fn start_scroll(&mut self) -> Result<(), String> {
        self.ensure_idle()?;
        let (d, r) = self.target()?;
        let image = self.frame(&d, r)?;
        self.stitcher = Some(ScrollStitcher::new(image).map_err(err)?);
        self.scroll_epoch += 1;
        self.previous_frame = None;
        self.state.scrolling = Some(ScrollState {
            active: true,
            preview_path: String::new(),
            accepted_frames: 1,
            status: "Faites défiler lentement vers le bas".into(),
        });
        self.write_scroll_preview()?;
        Ok(())
    }
    pub fn poll_scroll(&mut self) -> Result<(), String> {
        let (d, r) = self.target()?;
        let frame = self.frame(&d, r)?;
        // Accept only a viewport stable across two samples, preventing torn scroll frames.
        let stable = self
            .previous_frame
            .as_ref()
            .map(|p| {
                artshot_core::is_stable(
                    &image::DynamicImage::ImageRgba8(p.clone()).into_luma8(),
                    &image::DynamicImage::ImageRgba8(frame.clone()).into_luma8(),
                )
            })
            .unwrap_or(false);
        self.previous_frame = Some(frame.clone());
        if !stable {
            return Ok(());
        }
        if let Some(s) = &mut self.stitcher {
            match s.append(frame) {
                AppendResult::Accepted { .. } => {
                    if let Some(s) = &mut self.state.scrolling {
                        s.accepted_frames += 1;
                        s.status = "Position ajoutée".into();
                    }
                    self.write_scroll_preview()?;
                }
                AppendResult::Unchanged => {}
                AppendResult::Rejected => {
                    if let Some(s) = &mut self.state.scrolling {
                        s.status="Position ambiguë : revenez légèrement en arrière, puis avancez lentement".into();
                    }
                }
            }
        }
        Ok(())
    }
    pub fn write_scroll_preview(&mut self) -> Result<(), String> {
        if let Some(s) = &self.stitcher {
            let path = self.root.join("cache").join(format!(
                "scroll-{}-{}.png",
                self.scroll_epoch,
                self.state
                    .scrolling
                    .as_ref()
                    .map(|s| s.accepted_frames)
                    .unwrap_or(0)
            ));
            s.preview(320, 480).save(&path).map_err(err)?;
            if let Some(s) = &mut self.state.scrolling {
                s.preview_path = path.to_string_lossy().into();
            }
        }
        Ok(())
    }
    pub fn finish_scroll(&mut self) -> Result<MediaItem, String> {
        let image = self
            .stitcher
            .as_ref()
            .ok_or("Aucune capture défilante")?
            .preview(u32::MAX, u32::MAX);
        let item = self.add_image(image)?;
        self.stitcher = None;
        self.state.scrolling = None;
        self.previous_frame = None;
        self.scroll_epoch += 1;
        Ok(item)
    }
    pub fn start_recording(&mut self, options: RecordingOptions) -> Result<(), String> {
        self.ensure_idle()?;
        options.validate()?;
        #[cfg(target_os = "macos")]
        let mut options = options;
        #[cfg(target_os = "macos")]
        if options.camera && self.camera_preview_active {
            let status = self
                .bridge()?
                .request(json!({"action":"preview_status"}))
                .map_err(err)?;
            Self::apply_native_camera_layout(&mut options, &status["cameraLayout"])?;
        }
        #[cfg(target_os = "windows")]
        let camera_device = self.camera_preview.as_ref().map(|p| p.device.clone());
        #[cfg(target_os = "windows")]
        self.stop_preview()?;
        let (d, r) = self.target()?;
        let settings = serde_json::to_value(&options).map_err(err)?;
        atomic_json(&self.root.join("settings.json"), &settings)?;
        let directory = self
            .root
            .join("recordings")
            .join(Uuid::new_v4().to_string());
        fs::create_dir_all(&directory).map_err(err)?;
        atomic_json(
            &directory.join("capture-project.json"),
            &json!({"schemaVersion":1,"status":"capturing","options":options,"display":d,"region":r}),
        )?;
        #[cfg(target_os="macos")] self.bridge()?.request(json!({"action":"start","displayId":d.id,"region":r,"excludePid":std::process::id(),"directory":directory,"camera":options.camera,"microphone":options.microphone,"systemAudio":options.system_audio,"cursor":options.cursor,"clicks":options.clicks,"keys":options.keystrokes,"cameraLayout":options.layout()})).map_err(err)?;
        #[cfg(target_os = "windows")]
        {
            let native = artshot_platform::media::RecordingOptions {
                display_id: d.id,
                region: r,
                microphone: options.microphone,
                system_audio: options.system_audio,
                camera: options.camera,
                cursor: options.cursor,
                clicks: options.clicks,
                keystrokes: options.keystrokes,
                camera_device,
                ..Default::default()
            };
            self.recorder = Some(
                artshot_platform::media::Recorder::start(
                    self.resources.join("bin/ffmpeg.exe"),
                    &directory,
                    native,
                )
                .map_err(err)?,
            );
        }
        self.camera_preview_active = false;
        self.record_options = Some(options.clone());
        self.recording_directory = Some(directory);
        self.state.settings = settings;
        self.clock = Some(RecordingClock::new());
        self.state.recording = Some(RecordingState {
            active: true,
            paused: false,
            elapsed: 0.,
        });
        Ok(())
    }

    #[cfg(target_os = "macos")]
    fn apply_native_camera_layout(
        options: &mut RecordingOptions,
        layout: &Value,
    ) -> Result<(), String> {
        let layout: artshot_core::CameraLayout =
            serde_json::from_value(layout.clone()).map_err(err)?;
        options.camera_x = layout.center_x;
        options.camera_y = layout.center_y;
        options.camera_size = layout.width_fraction * 100.;
        options.camera_zoom = layout.zoom;
        options.camera_shape = match layout.shape {
            artshot_core::CameraShape::Circle => "circle",
            artshot_core::CameraShape::Square => "square",
            artshot_core::CameraShape::RoundedRectangle => "rounded",
            artshot_core::CameraShape::VerticalOval => "verticalOval",
        }
        .into();
        options.validate()
    }
    pub fn update_camera_preview(&mut self, settings: Value) -> Result<(), String> {
        if self.state.recording.is_some() {
            return Err("Réglages indisponibles pendant l’enregistrement".into());
        }
        let options: RecordingOptions = serde_json::from_value(settings.clone()).map_err(err)?;
        #[cfg(target_os = "macos")]
        let mut options = options;
        options.validate()?;
        if !options.camera || self.state.selection_display.is_none() {
            self.stop_preview()?;
            self.state.settings = settings;
            return Ok(());
        }
        #[cfg(target_os = "macos")]
        {
            let (d, r) = self.target()?;
            if self.camera_preview_active {
                let status = self
                    .bridge()?
                    .request(json!({"action":"preview_status"}))
                    .map_err(err)?;
                // Preserve a native drag while applying the UI's shape/size/zoom.
                if let Some(x) = status["cameraLayout"]["centerX"].as_f64() {
                    options.camera_x = x;
                }
                if let Some(y) = status["cameraLayout"]["centerY"].as_f64() {
                    options.camera_y = y;
                }
            }
            let status=self.bridge()?.request(json!({"action":"preview_camera","displayId":d.id,"region":r,"cameraLayout":options.layout()})).map_err(err)?;
            Self::apply_native_camera_layout(&mut options, &status["cameraLayout"])?;
        }
        #[cfg(target_os = "windows")]
        if self.camera_preview.is_none() {
            self.camera_preview = Some(
                artshot_platform::media::CameraPreview::start(
                    self.resources.join("bin/ffmpeg.exe"),
                    self.root.join("cache/camera"),
                    None,
                )
                .map_err(err)?,
            );
        }
        self.camera_preview_active = true;
        let settings = serde_json::to_value(options).map_err(err)?;
        #[cfg(target_os = "windows")]
        let settings = {
            let mut settings = settings;
            if let Some(preview) = &self.camera_preview {
                settings["cameraPreviewPath"] = json!(preview.path);
            }
            settings
        };
        self.state.settings = settings;
        Ok(())
    }
    pub fn stop_preview(&mut self) -> Result<(), String> {
        if self.state.recording.is_some() {
            return Ok(());
        }
        #[cfg(target_os = "macos")]
        if self.camera_preview_active {
            self.bridge()?
                .request(json!({"action":"stop_preview"}))
                .map_err(err)?;
        }
        #[cfg(target_os = "windows")]
        if let Some(preview) = self.camera_preview.take() {
            preview.stop().map_err(err)?;
        }
        self.camera_preview_active = false;
        if let Some(settings) = self.state.settings.as_object_mut() {
            settings.remove("cameraPreviewPath");
        }
        Ok(())
    }
    pub fn check_recording_health(&mut self) -> Result<(), String> {
        if self.state.recording.is_none() {
            return Ok(());
        }
        #[cfg(target_os = "macos")]
        let result = self
            .bridge()
            .and_then(|bridge| bridge.request(json!({"action":"status"})).map_err(err))
            .and_then(|status| {
                if status["active"] == true {
                    Ok(())
                } else {
                    Err("Le moteur natif a arrêté l’enregistrement".into())
                }
            });
        #[cfg(target_os = "windows")]
        let result = self
            .recorder
            .as_mut()
            .ok_or_else(|| "Moteur d’enregistrement indisponible".to_owned())
            .and_then(|r| r.check_running().map_err(err));
        if let Err(error) = result {
            let recovery = self.stop_recording(false).err();
            self.clear_recording();
            let message = if let Some(recovery) = recovery {
                format!("{error}. Récupération : {recovery}")
            } else {
                error
            };
            self.state.error = Some(message.clone());
            return Err(message);
        }
        Ok(())
    }
    pub fn pause_recording(&mut self, pause: bool) -> Result<(), String> {
        let current = self
            .state
            .recording
            .as_ref()
            .ok_or("Aucun enregistrement")?;
        if current.paused == pause {
            return Ok(());
        }
        #[cfg(target_os = "macos")]
        self.bridge()?
            .request(json!({"action":if pause{"pause"}else{"resume"}}))
            .map_err(err)?;
        #[cfg(target_os = "windows")]
        {
            let r = self.recorder.as_mut().ok_or("Aucun enregistrement")?;
            if pause {
                r.pause().map_err(err)?;
            } else {
                r.resume().map_err(err)?;
            }
        }
        if let Some(c) = &mut self.clock {
            if pause {
                c.pause()
            } else {
                c.resume()
            }
        }
        if let Some(r) = &mut self.state.recording {
            r.paused = pause;
        }
        Ok(())
    }
    fn clear_recording(&mut self) {
        self.state.recording = None;
        self.clock = None;
        self.record_options = None;
        self.recording_directory = None;
        if let Some(settings) = self.state.settings.as_object_mut() {
            settings.remove("cameraPreviewPath");
        }
    }
    pub fn stop_recording(&mut self, discard: bool) -> Result<Option<MediaItem>, String> {
        let options = self.record_options.clone().ok_or("Aucun enregistrement")?;
        let capture_directory = self.recording_directory.clone();
        #[cfg(target_os = "macos")]
        let (metadata, system_wav, microphone_wav) = {
            let result = self.bridge()?.request(json!({"action":"stop"}));
            self.clear_recording();
            let metadata = result.map_err(err)?;
            (metadata, None, None)
        };
        #[cfg(target_os = "windows")]
        let (metadata, system_wav, microphone_wav) = {
            let recorder = self.recorder.take().ok_or("Aucun enregistrement")?;
            // The capture handle is consumed even if stopping or assembly fails.
            // Clear the controls now; retained project files remain recoverable.
            self.clear_recording();
            let result = recorder.stop_with_audio().map_err(|e| {
                format!(
                    "{e}. Fichiers conservés dans {}",
                    capture_directory
                        .as_ref()
                        .map(|p| p.display().to_string())
                        .unwrap_or_default()
                )
            })?;
            let parent = result
                .segments
                .first()
                .and_then(|p| p.parent())
                .ok_or("Aucun segment vidéo ; consultez le dossier du projet")?
                .to_owned();
            atomic_json(
                &parent.join("capture-project.json"),
                &json!({"schemaVersion":1,"status":"captured","segments":result.segments,"systemWav":result.system_wav,"microphoneWav":result.microphone_wav,"options":options}),
            )?;
            if discard {
                trash::delete(capture_directory.as_ref().unwrap_or(&parent)).map_err(err)?;
                return Ok(None);
            }
            let path = parent.join("original.mkv");
            artshot_platform::media::concatenate(
                &self.resources.join("bin/ffmpeg.exe"),
                &result.segments,
                &path,
            )
            .map_err(|e| format!("{e}. Segments et audio conservés dans {}", parent.display()))?;
            let mut m =
                artshot_platform::media::probe(self.resources.join("bin/ffprobe.exe"), &path)
                    .map_err(|e| format!("{e}. Original conservé dans {}", parent.display()))?;
            m.camera = options.camera;
            m.system_audio = options.system_audio;
            m.microphone = options.microphone;
            (
                serde_json::to_value(m).map_err(err)?,
                result.system_wav,
                result.microphone_wav,
            )
        };
        let original = metadata["path"]
            .as_str()
            .ok_or("Le moteur n’a pas retourné de vidéo")?
            .to_owned();
        let parent = Path::new(&original)
            .parent()
            .ok_or("Dossier vidéo invalide")?
            .to_owned();
        if discard {
            trash::delete(capture_directory.as_ref().unwrap_or(&parent)).map_err(err)?;
            return Ok(None);
        }
        if let Some(warning) = metadata["warning"].as_str() {
            self.state.error = Some(warning.to_owned());
        }
        let mut options = options;
        options.camera &= metadata["camera"].as_bool().unwrap_or(false);
        options.microphone &= metadata["microphone"].as_bool().unwrap_or(false);
        options.system_audio &= metadata["system_audio"].as_bool().unwrap_or(false);
        let path = parent.join("preview.mp4");
        let id = Uuid::new_v4().to_string();
        let mut item = MediaItem {
            id,
            name: format!("Vidéo {}", chrono::Local::now().format("%d-%m %H.%M.%S")),
            kind: "video".into(),
            path: original.clone(),
            created_at: chrono::Utc::now().to_rfc3339(),
            width: metadata["width"].as_u64().unwrap_or(0) as u32,
            height: metadata["height"].as_u64().unwrap_or(0) as u32,
            duration: metadata["duration"].as_f64(),
            original_path: Some(original),
            recording_options: serde_json::to_value(&options).map_err(err)?,
            system_wav,
            microphone_wav,
        };
        // A per-project manifest preserves the immutable media even if the
        // library index or browser preview cannot be written.
        atomic_json(&parent.join("media.json"), &item)?;
        self.state.active_item_id = Some(item.id.clone());
        self.state.library.insert(0, item.clone());
        self.save()?;
        if let Err(error) = self.export_video(&item, &path, vec![], 1., 1.) {
            self.state.error = Some(format!(
                "Enregistrement conservé ; aperçu indisponible : {error}"
            ));
            return Ok(Some(item));
        }
        item.path = path.to_string_lossy().into();
        self.state.library[0] = item.clone();
        atomic_json(&parent.join("media.json"), &item)?;
        self.save()?;
        Ok(Some(item))
    }
    pub fn export_video(
        &mut self,
        item: &MediaItem,
        destination: &Path,
        cuts: Vec<Value>,
        microphone_gain: f64,
        system_gain: f64,
    ) -> Result<(), String> {
        if !(0.0..=2.0).contains(&microphone_gain) || !(0.0..=2.0).contains(&system_gain) {
            return Err("Le volume doit être compris entre 0 et 200 %".into());
        }
        let original = item.original_path.as_ref().unwrap_or(&item.path);
        #[cfg(target_os="macos")] self.bridge()?.request(json!({"action":"export","path":original,"destination":destination,"cuts":cuts,"microphoneGain":microphone_gain,"systemGain":system_gain,"camera":item.recording_options["camera"].as_bool().unwrap_or(true),"clicks":item.recording_options["clicks"].as_bool().unwrap_or(true),"keys":item.recording_options["keystrokes"].as_bool().unwrap_or(true)})).map_err(err)?;
        #[cfg(target_os = "windows")]
        {
            use artshot_platform::media::{export_mp4, TrackManifest};
            let o: crate::model::RecordingOptions =
                serde_json::from_value(item.recording_options.clone()).map_err(err)?;
            let manifest = TrackManifest {
                path: PathBuf::from(original),
                duration: item.duration.unwrap_or(0.),
                width: item.width,
                height: item.height,
                camera: o.camera,
                system_audio: o.system_audio,
                microphone: o.microphone,
            };
            let typed_cuts = cuts
                .into_iter()
                .map(serde_json::from_value)
                .collect::<Result<Vec<_>, _>>()
                .map_err(err)?;
            let edits = o.export_options(typed_cuts, microphone_gain, system_gain)?;
            export_mp4(
                &self.resources.join("bin/ffmpeg.exe"),
                &manifest,
                &edits,
                destination,
                item.system_wav.as_deref(),
                item.microphone_wav.as_deref(),
            )
            .map_err(err)?;
        }
        Ok(())
    }
}
pub fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}
pub fn atomic_json(path: &Path, value: &impl serde::Serialize) -> Result<(), String> {
    use std::io::Write;
    let temp = path.with_extension(format!("{}.tmp", Uuid::new_v4()));
    let result = (|| {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)
            .map_err(err)?;
        file.write_all(&serde_json::to_vec_pretty(value).map_err(err)?)
            .map_err(err)?;
        file.sync_all().map_err(err)?;
        drop(file);
        #[cfg(target_os = "windows")]
        {
            use std::os::windows::ffi::OsStrExt;
            use windows::Win32::Storage::FileSystem::{
                MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
            };
            let from: Vec<u16> = temp.as_os_str().encode_wide().chain(Some(0)).collect();
            let to: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
            unsafe {
                MoveFileExW(
                    windows::core::PCWSTR(from.as_ptr()),
                    windows::core::PCWSTR(to.as_ptr()),
                    MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
                )
            }
            .map_err(err)?;
        }
        #[cfg(not(target_os = "windows"))]
        {
            fs::rename(&temp, path).map_err(err)?;
            if let Some(parent) = path.parent() {
                fs::File::open(parent)
                    .and_then(|f| f.sync_all())
                    .map_err(err)?;
            }
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}
#[cfg(test)]
mod tests {
    use super::*;
    fn test_directory() -> PathBuf {
        let path = std::env::temp_dir().join(format!("artshot-backend-{}", Uuid::new_v4()));
        fs::create_dir_all(&path).unwrap();
        path
    }
    #[test]
    fn settings_failure_prevents_native_recording_start() {
        let root = test_directory();
        let mut backend = Backend::new(root.clone(), root.clone()).unwrap();
        backend.display = Some(Display {
            id: 1,
            name: "Test display".into(),
            x: 0,
            y: 0,
            width: 1920,
            height: 1080,
            scale_factor: 1.,
        });
        fs::create_dir(root.join("settings.json")).unwrap();
        assert!(backend
            .start_recording(RecordingOptions::default())
            .is_err());
        assert!(backend.state.recording.is_none());
        assert!(backend.clock.is_none());
        assert!(backend.native.is_none());
        assert!(backend.record_options.is_none());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn failed_scroll_save_keeps_composite() {
        let root = test_directory();
        let mut backend = Backend::new(root.clone(), root.clone()).unwrap();
        backend.stitcher = Some(ScrollStitcher::new(RgbaImage::new(48, 180)).unwrap());
        backend.state.scrolling = Some(ScrollState {
            active: true,
            preview_path: String::new(),
            accepted_frames: 1,
            status: String::new(),
        });
        fs::remove_dir(root.join("captures")).unwrap();
        fs::write(root.join("captures"), b"block writes").unwrap();
        assert!(backend.finish_scroll().is_err());
        assert!(backend.stitcher.is_some());
        assert!(backend.state.scrolling.is_some());
        assert!(backend.state.library.is_empty());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn json_replace_preserves_previous_document_on_serialization_failure() {
        struct Fails;
        impl serde::Serialize for Fails {
            fn serialize<S: serde::Serializer>(&self, _serializer: S) -> Result<S::Ok, S::Error> {
                Err(serde::ser::Error::custom("injected failure"))
            }
        }
        let root = test_directory();
        let path = root.join("library.json");
        atomic_json(&path, &json!([{"id":"original"}])).unwrap();
        let before = fs::read(&path).unwrap();
        assert!(atomic_json(&path, &Fails).is_err());
        assert_eq!(fs::read(&path).unwrap(), before);
        assert_eq!(fs::read_dir(&root).unwrap().count(), 1);
        atomic_json(&path, &json!([{"id":"replacement"}])).unwrap();
        assert_ne!(fs::read(&path).unwrap(), before);
        fs::remove_dir_all(root).unwrap();
    }
}
