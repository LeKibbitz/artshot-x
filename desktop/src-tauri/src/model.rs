use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    path::PathBuf,
    time::{Duration, Instant},
};
#[derive(Clone, Serialize, Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct MediaItem {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub path: String,
    pub created_at: String,
    pub width: u32,
    pub height: u32,
    pub duration: Option<f64>,
    #[serde(default)]
    pub original_path: Option<String>,
    #[serde(default)]
    pub recording_options: Value,
    #[serde(default)]
    pub system_wav: Option<PathBuf>,
    #[serde(default)]
    pub microphone_wav: Option<PathBuf>,
}
#[derive(Clone, Copy, Serialize, Deserialize, Debug)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
impl Rect {
    pub fn region(
        self,
        display: &artshot_platform::Display,
    ) -> Result<artshot_platform::Region, String> {
        if [self.x, self.y, self.width, self.height]
            .iter()
            .any(|v| !v.is_finite())
        {
            return Err("Zone invalide".into());
        }
        let r = artshot_platform::Region {
            x: self.x.round() as i32,
            y: self.y.round() as i32,
            width: self.width.round().max(0.) as u32,
            height: self.height.round().max(0.) as u32,
        };
        artshot_platform::validate_region(r, display.width, display.height)
            .map_err(|e| e.to_string())?;
        Ok(r)
    }
}
#[derive(Clone, Serialize, Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct SelectionDisplay {
    pub id: String,
    pub width: u32,
    pub height: u32,
    pub scale_factor: f32,
    pub background_path: String,
}
#[derive(Clone, Serialize, Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct ScrollState {
    pub active: bool,
    pub preview_path: String,
    pub accepted_frames: u32,
    pub status: String,
}
#[derive(Clone, Serialize, Deserialize, Debug)]
pub struct RecordingState {
    pub active: bool,
    pub paused: bool,
    pub elapsed: f64,
}
#[derive(Clone, Serialize, Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct AppState {
    pub library: Vec<MediaItem>,
    pub selection: Option<Rect>,
    pub selection_display: Option<SelectionDisplay>,
    pub selection_mode: String,
    pub recording: Option<RecordingState>,
    pub scrolling: Option<ScrollState>,
    pub settings: Value,
    pub error: Option<String>,
    pub active_item_id: Option<String>,
    pub shortcut_errors: Vec<String>,
    pub capabilities: Value,
}
impl Default for AppState {
    fn default() -> Self {
        Self {
            library: vec![],
            selection: None,
            selection_display: None,
            selection_mode: "menu".into(),
            recording: None,
            scrolling: None,
            settings: json!({"cameraShape":"circle","cameraSize":24,"cameraZoom":1}),
            error: None,
            active_item_id: None,
            shortcut_errors: vec![],
            capabilities: json!({"recording":true,"systemAudio":true,"microphone":true,"camera":true}),
        }
    }
}
pub struct RecordingClock {
    accumulated: Duration,
    start: Option<Instant>,
}
impl RecordingClock {
    pub fn new() -> Self {
        Self {
            accumulated: Duration::ZERO,
            start: Some(Instant::now()),
        }
    }
    pub fn pause(&mut self) {
        if let Some(t) = self.start.take() {
            self.accumulated += t.elapsed();
        }
    }
    pub fn resume(&mut self) {
        if self.start.is_none() {
            self.start = Some(Instant::now());
        }
    }
    pub fn elapsed(&self) -> f64 {
        (self.accumulated + self.start.map(|s| s.elapsed()).unwrap_or_default()).as_secs_f64()
    }
}
#[derive(Clone, Serialize, Deserialize, Debug)]
#[serde(rename_all = "camelCase", default)]
pub struct RecordingOptions {
    pub microphone: bool,
    pub system_audio: bool,
    pub camera: bool,
    pub camera_shape: String,
    pub camera_size: f64,
    pub camera_zoom: f64,
    pub camera_x: f64,
    pub camera_y: f64,
    pub cursor: bool,
    pub clicks: bool,
    pub keystrokes: bool,
}
impl Default for RecordingOptions {
    fn default() -> Self {
        Self {
            microphone: true,
            system_audio: true,
            camera: false,
            camera_shape: "circle".into(),
            camera_size: 24.,
            camera_zoom: 1.,
            camera_x: 0.78,
            camera_y: 0.68,
            cursor: true,
            clicks: false,
            keystrokes: false,
        }
    }
}
impl RecordingOptions {
    pub fn layout(&self) -> Value {
        json!({"shape":if self.camera_shape=="rounded"{"roundedRectangle"}else{&self.camera_shape},"widthFraction":(self.camera_size/100.).clamp(0.12,0.45),"centerX":self.camera_x.clamp(0.,1.),"centerY":self.camera_y.clamp(0.,1.),"zoom":self.camera_zoom.clamp(1.,3.)})
    }
}

impl RecordingOptions {
    pub fn validate(&self) -> Result<(), String> {
        if !matches!(
            self.camera_shape.as_str(),
            "circle" | "square" | "rounded" | "roundedRectangle" | "verticalOval"
        ) {
            return Err("Forme de caméra invalide".into());
        }
        for (value, minimum, maximum, name) in [
            (self.camera_size, 12., 45., "taille"),
            (self.camera_zoom, 1., 3., "zoom"),
            (self.camera_x, 0., 1., "position X"),
            (self.camera_y, 0., 1., "position Y"),
        ] {
            if !value.is_finite() || value < minimum || value > maximum {
                return Err(format!("Caméra : {name} invalide"));
            }
        }
        Ok(())
    }
    #[cfg(any(target_os = "windows", test))]
    pub fn export_options(
        &self,
        cuts: Vec<artshot_platform::media::Cut>,
        microphone_gain: f64,
        system_gain: f64,
    ) -> Result<artshot_platform::media::ExportOptions, String> {
        self.validate()?;
        if !(0.0..=2.0).contains(&microphone_gain) || !(0.0..=2.0).contains(&system_gain) {
            return Err("Le volume doit être compris entre 0 et 200 %".into());
        }
        Ok(artshot_platform::media::ExportOptions {
            cuts,
            microphone_gain,
            system_gain,
            camera: self.camera,
            clicks: self.clicks,
            keys: self.keystrokes,
            camera_shape: if self.camera_shape == "rounded" {
                "roundedRectangle".into()
            } else {
                self.camera_shape.clone()
            },
            camera_size: self.camera_size / 100.,
            camera_x: self.camera_x,
            camera_y: self.camera_y,
            camera_zoom: self.camera_zoom,
            ..Default::default()
        })
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ui_settings_preserve_audio_and_camera_export() {
        let options:RecordingOptions=serde_json::from_value(json!({"systemAudio":true,"microphone":false,"camera":true,"cameraShape":"rounded","cameraSize":36,"cameraZoom":2,"cameraX":0.4,"cameraY":0.6})).unwrap();
        assert!(options.system_audio);
        assert!(!options.microphone);
        let export = options.export_options(vec![], 0.5, 1.5).unwrap();
        assert_eq!(export.camera_size, 0.36);
        assert_eq!(export.camera_shape, "roundedRectangle");
        assert_eq!(export.camera_zoom, 2.);
        assert_eq!(export.system_gain, 1.5);
    }
    #[test]
    fn reject_invalid_options_before_capture() {
        for bad in [
            RecordingOptions {
                camera_zoom: f64::NAN,
                ..Default::default()
            },
            RecordingOptions {
                camera_size: 100.,
                ..Default::default()
            },
            RecordingOptions {
                camera_x: -1.,
                ..Default::default()
            },
            RecordingOptions {
                camera_shape: "triangle".into(),
                ..Default::default()
            },
        ] {
            assert!(bad.validate().is_err());
        }
        assert!(RecordingOptions::default()
            .export_options(vec![], f64::NAN, 1.)
            .is_err());
    }
}
