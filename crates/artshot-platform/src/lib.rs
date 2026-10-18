//! Native capture uses physical pixels relative to a selected display.
pub use image::RgbaImage;
use serde::{Deserialize, Serialize};
use std::{
    io::{BufRead, BufReader, Write},
    path::Path,
    process::{Child, ChildStdin, ChildStdout, Command, Stdio},
};

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("{0}")]
    Native(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error(transparent)]
    Image(#[from] image::ImageError),
}
pub type Result<T> = std::result::Result<T, Error>;
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Display {
    pub id: u32,
    pub name: String,
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub scale_factor: f32,
}
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct Region {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}
fn native(e: impl std::fmt::Display) -> Error {
    Error::Native(e.to_string())
}
pub fn list_displays() -> Result<Vec<Display>> {
    xcap::Monitor::all()
        .map_err(native)?
        .into_iter()
        .map(|m| {
            let scale = m.scale_factor().map_err(native)?;
            let x = m.x().map_err(native)?;
            let y = m.y().map_err(native)?;
            let width = m.width().map_err(native)?;
            let height = m.height().map_err(native)?;
            // xcap's macOS monitor dimensions are CoreGraphics points, despite its public docs.
            #[cfg(target_os = "macos")]
            let (x, y, width, height) = (
                (x as f32 * scale).round() as i32,
                (y as f32 * scale).round() as i32,
                (width as f32 * scale).round() as u32,
                (height as f32 * scale).round() as u32,
            );
            Ok(Display {
                id: m.id().map_err(native)?,
                name: m.friendly_name().map_err(native)?,
                x,
                y,
                width,
                height,
                scale_factor: scale,
            })
        })
        .collect()
}
/// Basic screenshot. For macOS own-window exclusion use NativeBridge::capture_png.
pub fn capture(display_id: u32, region: Option<Region>) -> Result<RgbaImage> {
    let monitor = xcap::Monitor::all()
        .map_err(native)?
        .into_iter()
        .find(|m| m.id().ok() == Some(display_id))
        .ok_or_else(|| native("Display unavailable"))?;
    let image = monitor.capture_image().map_err(native)?;
    match region {
        None => Ok(image),
        Some(r) => {
            validate_region(r, image.width(), image.height())?;
            Ok(
                image::imageops::crop_imm(&image, r.x as u32, r.y as u32, r.width, r.height)
                    .to_image(),
            )
        }
    }
}
pub fn validate_region(r: Region, width: u32, height: u32) -> Result<()> {
    if r.x < 0
        || r.y < 0
        || r.width == 0
        || r.height == 0
        || r.x as u64 + r.width as u64 > width as u64
        || r.y as u64 + r.height as u64 > height as u64
    {
        Err(native("Invalid capture region"))
    } else {
        Ok(())
    }
}
pub fn capture_png(display_id: u32, region: Option<Region>, path: impl AsRef<Path>) -> Result<()> {
    capture(display_id, region)?.save(path)?;
    Ok(())
}

/// Long-lived macOS helper; serialize access behind the application state mutex.
/// All requests return one JSON line. EOF cancels active capture.
pub struct NativeBridge {
    child: Child,
    input: ChildStdin,
    output: BufReader<ChildStdout>,
}
impl NativeBridge {
    pub fn spawn(path: impl AsRef<Path>) -> Result<Self> {
        let mut child = Command::new(path.as_ref())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()?;
        let input = child
            .stdin
            .take()
            .ok_or_else(|| native("Missing helper stdin"))?;
        let output = BufReader::new(
            child
                .stdout
                .take()
                .ok_or_else(|| native("Missing helper stdout"))?,
        );
        Ok(Self {
            child,
            input,
            output,
        })
    }
    pub fn request(&mut self, value: serde_json::Value) -> Result<serde_json::Value> {
        serde_json::to_writer(&mut self.input, &value)?;
        self.input.write_all(b"\n")?;
        self.input.flush()?;
        let mut line = String::new();
        if self.output.read_line(&mut line)? == 0 {
            return Err(native("Native helper exited unexpectedly"));
        }
        let result: serde_json::Value = serde_json::from_str(&line)?;
        if result["ok"] == false {
            return Err(native(
                result["error"]
                    .as_str()
                    .unwrap_or("Native operation failed"),
            ));
        }
        Ok(result)
    }
    pub fn capture_png(
        &mut self,
        display_id: u32,
        region: Option<Region>,
        path: impl AsRef<Path>,
        exclude_pid: u32,
    ) -> Result<()> {
        self.request(serde_json::json!({"action":"capture","displayId":display_id,"region":region,"path":path.as_ref(),"excludePid":exclude_pid}))?;
        Ok(())
    }
}
impl Drop for NativeBridge {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
pub mod media;

#[cfg(target_os = "windows")]
pub mod windows_audio;

#[cfg(target_os = "windows")]
pub mod windows_events;
