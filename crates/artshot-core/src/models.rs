use crate::{CameraLayout, Point, RecordingEdit, Rect};
use image::{Rgba, RgbaImage};
use serde::{Deserialize, Serialize};
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Annotation {
    Arrow {
        start: Point,
        end: Point,
        color: [u8; 4],
        width: f32,
    },
    Rectangle {
        rect: Rect,
        color: [u8; 4],
        width: f32,
    },
    NumberedStep {
        center: Point,
        number: u32,
        radius: f32,
        color: [u8; 4],
    },
}
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ImageEdit {
    pub annotations: Vec<Annotation>,
}
/// Immutable media paths with a separate edit manifest. Paths are relative to the project directory.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImageProject {
    pub schema_version: u32,
    pub id: String,
    pub original: String,
    pub width: u32,
    pub height: u32,
    pub edit: ImageEdit,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct RecordingOptions {
    pub camera: bool,
    pub microphone: bool,
    pub system_audio: bool,
    pub cursor: bool,
    pub clicks: bool,
    pub keys: bool,
    pub camera_layout: Option<CameraLayout>,
}
impl Default for RecordingOptions {
    fn default() -> Self {
        Self {
            camera: false,
            microphone: false,
            system_audio: false,
            cursor: true,
            clicks: false,
            keys: false,
            camera_layout: None,
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordingProject {
    pub schema_version: u32,
    pub id: String,
    pub screen: String,
    pub camera: Option<String>,
    pub microphone: Option<String>,
    pub system_audio: Option<String>,
    pub duration: f64,
    pub width: u32,
    pub height: u32,
    pub options: RecordingOptions,
    pub edit: RecordingEdit,
}
/// Snapshot history stores decisions only, never mutates original media.
#[derive(Clone, Debug)]
pub struct EditHistory<T> {
    current: T,
    undo: Vec<T>,
    redo: Vec<T>,
}
impl<T: Clone + PartialEq> EditHistory<T> {
    pub fn new(current: T) -> Self {
        Self {
            current,
            undo: vec![],
            redo: vec![],
        }
    }
    pub fn current(&self) -> &T {
        &self.current
    }
    pub fn apply(&mut self, value: T) {
        if value != self.current {
            self.undo.push(self.current.clone());
            self.current = value;
            self.redo.clear();
        }
    }
    pub fn undo(&mut self) -> bool {
        if let Some(v) = self.undo.pop() {
            self.redo.push(std::mem::replace(&mut self.current, v));
            true
        } else {
            false
        }
    }
    pub fn redo(&mut self) -> bool {
        if let Some(v) = self.redo.pop() {
            self.undo.push(std::mem::replace(&mut self.current, v));
            true
        } else {
            false
        }
    }
}
fn blend(image: &mut RgbaImage, x: u32, y: u32, color: [u8; 4]) {
    let dst = image.get_pixel_mut(x, y);
    let a = color[3] as f64 / 255.;
    let da = dst[3] as f64 / 255.;
    let oa = a + da * (1. - a);
    if oa <= 0. {
        return;
    }
    let mut out = [0; 4];
    for i in 0..3 {
        out[i] = ((color[i] as f64 * a + dst[i] as f64 * da * (1. - a)) / oa).round() as u8;
    }
    out[3] = (oa * 255.).round() as u8;
    *dst = Rgba(out);
}
fn disk(image: &mut RgbaImage, c: Point, r: f64, color: [u8; 4]) {
    if !c.x.is_finite() || !c.y.is_finite() || !r.is_finite() || r <= 0. {
        return;
    }
    let x0 = (c.x - r).floor().max(0.) as u32;
    let x1 = (c.x + r).ceil().max(0.).min(image.width() as f64) as u32;
    let y0 = (c.y - r).floor().max(0.) as u32;
    let y1 = (c.y + r).ceil().max(0.).min(image.height() as f64) as u32;
    for y in y0..y1 {
        for x in x0..x1 {
            if (x as f64 + 0.5 - c.x).powi(2) + (y as f64 + 0.5 - c.y).powi(2) <= r * r {
                blend(image, x, y, color)
            }
        }
    }
}
fn line(image: &mut RgbaImage, a: Point, b: Point, width: f64, color: [u8; 4]) {
    if ![a.x, a.y, b.x, b.y, width].iter().all(|v| v.is_finite()) || width <= 0. {
        return;
    }
    let r = width / 2.;
    let x0 = (a.x.min(b.x) - r).floor().max(0.) as u32;
    let x1 = (a.x.max(b.x) + r).ceil().max(0.).min(image.width() as f64) as u32;
    let y0 = (a.y.min(b.y) - r).floor().max(0.) as u32;
    let y1 = (a.y.max(b.y) + r).ceil().max(0.).min(image.height() as f64) as u32;
    let dx = b.x - a.x;
    let dy = b.y - a.y;
    let len = dx * dx + dy * dy;
    for y in y0..y1 {
        for x in x0..x1 {
            let px = x as f64 + 0.5;
            let py = y as f64 + 0.5;
            let t = if len > 0. {
                ((px - a.x) * dx + (py - a.y) * dy) / len
            } else {
                0.
            }
            .clamp(0., 1.);
            if (px - a.x - t * dx).powi(2) + (py - a.y - t * dy).powi(2) <= r * r {
                blend(image, x, y, color)
            }
        }
    }
}
/// Rasterizes onto an exact-size copy. Number glyphs use bundled 3×5 bitmaps.
pub fn render_annotations(original: &RgbaImage, edit: &ImageEdit) -> RgbaImage {
    let mut out = original.clone();
    for annotation in &edit.annotations {
        match annotation {
            Annotation::Arrow {
                start,
                end,
                color,
                width,
            } => {
                line(&mut out, *start, *end, *width as f64, *color);
                let dx = end.x - start.x;
                let dy = end.y - start.y;
                let len = dx.hypot(dy);
                if len > 0. {
                    let head = (*width as f64 * 4.).max(10.).min(len);
                    let ux = dx / len;
                    let uy = dy / len;
                    for sign in [-1., 1.] {
                        line(
                            &mut out,
                            *end,
                            Point {
                                x: end.x - head * ux + sign * head * 0.5 * uy,
                                y: end.y - head * uy - sign * head * 0.5 * ux,
                            },
                            *width as f64,
                            *color,
                        );
                    }
                }
            }
            Annotation::Rectangle { rect, color, width } => {
                if !rect.is_valid() {
                    continue;
                }
                let a = Point {
                    x: rect.x,
                    y: rect.y,
                };
                let b = Point {
                    x: rect.x + rect.width,
                    y: rect.y,
                };
                let c = Point {
                    x: b.x,
                    y: rect.y + rect.height,
                };
                let d = Point { x: a.x, y: c.y };
                for (a, b) in [(a, b), (b, c), (c, d), (d, a)] {
                    line(&mut out, a, b, *width as f64, *color)
                }
            }
            Annotation::NumberedStep {
                center,
                number,
                radius,
                color,
            } => {
                disk(&mut out, *center, *radius as f64, *color);
                if !radius.is_finite()
                    || *radius <= 0.
                    || !center.x.is_finite()
                    || !center.y.is_finite()
                {
                    continue;
                }
                let label = number.to_string();
                let scale = (*radius as f64 * 1.15 / (label.len() * 4 - 1).max(5) as f64).max(1.);
                let left = center.x - (label.len() * 4 - 1) as f64 * scale / 2.;
                let top = center.y - 5. * scale / 2.;
                const DIGITS: [[u8; 5]; 10] = [
                    [7, 5, 5, 5, 7],
                    [2, 6, 2, 2, 7],
                    [7, 1, 7, 4, 7],
                    [7, 1, 7, 1, 7],
                    [5, 5, 7, 1, 1],
                    [7, 4, 7, 1, 7],
                    [7, 4, 7, 5, 7],
                    [7, 1, 1, 1, 1],
                    [7, 5, 7, 5, 7],
                    [7, 5, 7, 1, 7],
                ];
                for (i, ch) in label.bytes().enumerate() {
                    for (row, bits) in DIGITS[(ch - b'0') as usize].iter().enumerate() {
                        for col in 0..3 {
                            if bits & (1 << (2 - col)) != 0 {
                                let x0 =
                                    (left + (i * 4 + col) as f64 * scale).round().max(0.) as u32;
                                let y0 = (top + row as f64 * scale).round().max(0.) as u32;
                                let x1 = (left + (i * 4 + col + 1) as f64 * scale)
                                    .round()
                                    .max(0.)
                                    .min(out.width() as f64)
                                    as u32;
                                let y1 = (top + (row + 1) as f64 * scale)
                                    .round()
                                    .max(0.)
                                    .min(out.height() as f64)
                                    as u32;
                                for y in y0..y1 {
                                    for x in x0..x1 {
                                        blend(&mut out, x, y, [255, 255, 255, 255])
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    out
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn original_and_dimensions_preserved() {
        let original = RgbaImage::from_pixel(31, 27, Rgba([0, 0, 0, 255]));
        let edit = ImageEdit {
            annotations: vec![
                Annotation::Rectangle {
                    rect: Rect {
                        x: 2.,
                        y: 2.,
                        width: 10.,
                        height: 8.,
                    },
                    color: [255, 0, 0, 255],
                    width: 2.,
                },
                Annotation::NumberedStep {
                    center: Point { x: 22., y: 15. },
                    number: 12,
                    radius: 7.,
                    color: [0, 0, 255, 255],
                },
            ],
        };
        let result = render_annotations(&original, &edit);
        assert_eq!(result.dimensions(), (31, 27));
        assert_eq!(original.get_pixel(2, 2)[0], 0);
        assert_eq!(result.get_pixel(2, 2)[0], 255);
        let mut png = std::io::Cursor::new(vec![]);
        result.write_to(&mut png, image::ImageFormat::Png).unwrap();
        assert_eq!(image::load_from_memory(png.get_ref()).unwrap().width(), 31);
        assert_eq!(
            serde_json::from_str::<ImageEdit>(&serde_json::to_string(&edit).unwrap()).unwrap(),
            edit
        );
    }
    #[test]
    fn undo_branch() {
        let mut h = EditHistory::new(ImageEdit::default());
        h.apply(ImageEdit {
            annotations: vec![Annotation::NumberedStep {
                center: Point { x: 1., y: 1. },
                number: 1,
                radius: 5.,
                color: [255; 4],
            }],
        });
        assert!(h.undo());
        assert!(h.redo());
        assert!(h.undo());
        h.apply(ImageEdit::default());
        assert!(h.redo());
    }
}
