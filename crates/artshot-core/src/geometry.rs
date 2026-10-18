use serde::{Deserialize, Serialize};
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
impl Rect {
    pub fn between(a: Point, b: Point) -> Self {
        Self {
            x: a.x.min(b.x),
            y: a.y.min(b.y),
            width: (a.x - b.x).abs(),
            height: (a.y - b.y).abs(),
        }
    }
    pub fn is_valid(self) -> bool {
        [self.x, self.y, self.width, self.height]
            .iter()
            .all(|v| v.is_finite())
            && self.width > 0.
            && self.height > 0.
    }
    pub fn standardized(self) -> Self {
        Self {
            x: self.x.min(self.x + self.width),
            y: self.y.min(self.y + self.height),
            width: self.width.abs(),
            height: self.height.abs(),
        }
    }
    pub fn intersection(self, b: Self) -> Option<Self> {
        let self_rect = self.standardized();
        let b = b.standardized();
        self_rect.intersection_positive(b)
    }
    fn intersection_positive(self, b: Self) -> Option<Self> {
        if !self.is_valid() || !b.is_valid() {
            return None;
        }
        let x = self.x.max(b.x);
        let y = self.y.max(b.y);
        let r = Self {
            x,
            y,
            width: (self.x + self.width).min(b.x + b.width) - x,
            height: (self.y + self.height).min(b.y + b.height) - y,
        };
        r.is_valid().then_some(r)
    }
    /// Global top-left coordinates to display-local physical pixels.
    pub fn display_local(self, display: Self) -> Option<Self> {
        let display = display.standardized();
        self.intersection(display).map(|r| Self {
            x: r.x - display.x,
            y: r.y - display.y,
            ..r
        })
    }
    pub fn aligned_pixels(self) -> Option<Self> {
        if !self.is_valid() {
            return None;
        }
        Some(Self {
            x: self.x.floor(),
            y: self.y.floor(),
            width: (self.x + self.width).ceil() - self.x.floor(),
            height: (self.y + self.height).ceil() - self.y.floor(),
        })
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum CameraShape {
    Circle,
    Square,
    #[default]
    RoundedRectangle,
    VerticalOval,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct CameraLayout {
    pub shape: CameraShape,
    pub width_fraction: f64,
    pub center_x: f64,
    pub center_y: f64,
    pub zoom: f64,
}
impl Default for CameraLayout {
    fn default() -> Self {
        Self {
            shape: CameraShape::RoundedRectangle,
            width_fraction: 0.23,
            center_x: 0.84,
            center_y: 0.82,
            zoom: 1.,
        }
    }
}
fn bounded(v: f64, lo: f64, hi: f64, fallback: f64) -> f64 {
    if v.is_finite() {
        v.clamp(lo, hi)
    } else {
        fallback
    }
}
impl CameraLayout {
    pub fn effective_zoom(&self) -> f64 {
        bounded(self.zoom, 1., 3., 1.)
    }
    pub fn frame(&self, width: f64, height: f64) -> Rect {
        if !width.is_finite() || !height.is_finite() || width <= 0. || height <= 0. {
            return Rect::default();
        }
        let ratio = match self.shape {
            CameraShape::Circle | CameraShape::Square => 1.,
            CameraShape::RoundedRectangle => 4. / 3.,
            CameraShape::VerticalOval => 3. / 4.,
        };
        let w = (width * bounded(self.width_fraction, 0.12, 0.45, 0.23)).min(height * ratio);
        let h = w / ratio;
        Rect {
            x: (width * bounded(self.center_x, 0., 1., 0.84) - w / 2.).clamp(0., width - w),
            y: (height * bounded(self.center_y, 0., 1., 0.82) - h / 2.).clamp(0., height - h),
            width: w,
            height: h,
        }
    }
    pub fn image_frame(&self, source_width: f64, source_height: f64, bounds: Rect) -> Rect {
        if !bounds.is_valid()
            || !source_width.is_finite()
            || !source_height.is_finite()
            || source_width <= 0.
            || source_height <= 0.
        {
            return Rect::default();
        }
        let scale = (bounds.width / source_width).max(bounds.height / source_height)
            * self.effective_zoom();
        let w = source_width * scale;
        let h = source_height * scale;
        Rect {
            x: bounds.x + (bounds.width - w) / 2.,
            y: bounds.y + (bounds.height - h) / 2.,
            width: w,
            height: h,
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn negative_display_origin() {
        assert_eq!(
            Rect {
                x: -1800.2,
                y: 20.,
                width: 100.,
                height: 50.
            }
            .display_local(Rect {
                x: -1920.,
                y: 0.,
                width: 1920.,
                height: 1080.
            })
            .unwrap()
            .x,
            119.79999999999995
        );
    }
    #[test]
    fn zoom_preserves_center() {
        let c = CameraLayout {
            zoom: 3.,
            ..Default::default()
        };
        let b = c.frame(1920., 1080.);
        let f = c.image_frame(640., 480., b);
        assert!((f.x + f.width / 2. - b.x - b.width / 2.).abs() < 1e-8);
        assert_eq!(serde_json::from_str::<CameraLayout>("{}").unwrap().zoom, 1.);
    }
}
