use image::{
    imageops::{self, FilterType},
    GrayImage, RgbaImage,
};
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScrollAlignment {
    Duplicate,
    Shifted { pixels: u32 },
    Unalignable,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AppendResult {
    Accepted { rows: u32 },
    Unchanged,
    Rejected,
}
fn unchanged(a: &GrayImage, b: &GrayImage, tolerance: f64) -> bool {
    let mut total = 0.;
    for (x, y) in a.as_raw().iter().zip(b.as_raw()) {
        let d = (*x as f64 - *y as f64).abs();
        if d > 6. {
            return false;
        }
        total += d;
    }
    total / a.as_raw().len() as f64 <= tolerance
}
pub fn is_stable(a: &GrayImage, b: &GrayImage) -> bool {
    a.dimensions() == b.dimensions() && a.width() > 0 && a.height() > 0 && unchanged(a, b, 0.65)
}
fn score(
    a: &GrayImage,
    b: &GrayImage,
    shift: u32,
    top: u32,
    bottom: u32,
    xstep: u32,
    ystep: u32,
) -> f64 {
    let w = a.width();
    let margin = (w / 20).max(1);
    let last = a.height() - bottom - shift;
    let mut error = 0.;
    let mut weight = 0.;
    let mut detail = 0.;
    for row in (top..last).step_by(ystep as usize) {
        let jitter = (((row / ystep) as u64 * 1_103_515_245 + 12_345) & 0x7fff_ffff) >> 8;
        let y = (row + (jitter as u32 % ystep)).min(last - 1);
        for x in (margin..w - margin).step_by(xstep as usize) {
            let p = |im: &GrayImage, x, y| im.get_pixel(x, y).0[0] as f64;
            let g = (p(a, x, y + shift) - p(a, x - xstep, y + shift)).abs()
                + (p(b, x, y) - p(b, x - xstep, y)).abs()
                + (p(a, x, y + shift) - p(a, x, y + shift - 1)).abs()
                + (p(b, x, y) - p(b, x, y - 1)).abs();
            let pw = 1. + (g / 8.).min(12.);
            error += (p(a, x, y + shift) - p(b, x, y)).abs() * pw;
            weight += pw;
            detail += g;
        }
    }
    if weight == 0. || detail / weight <= 0.12 {
        f64::INFINITY
    } else {
        error / weight
    }
}
fn fixed_footer(a: &GrayImage, b: &GrayImage) -> bool {
    let w = a.width();
    let mut rows = 0;
    let mut lo = 255;
    let mut hi = 0;
    for y in (a.height() * 9 / 10..a.height()).rev() {
        let mut error = 0.;
        for x in w / 20..w - w / 20 {
            error += (a.get_pixel(x, y).0[0] as f64 - b.get_pixel(x, y).0[0] as f64).abs();
        }
        if error / (w - 2 * (w / 20)) as f64 > 0.65 {
            break;
        }
        rows += 1;
        for x in w / 20..w - w / 20 {
            let v = a.get_pixel(x, y).0[0];
            lo = lo.min(v);
            hi = hi.max(v);
        }
    }
    rows >= 6.max(a.height() / 100) && hi - lo > 24
}
pub fn align(a: &GrayImage, b: &GrayImage) -> ScrollAlignment {
    if a.dimensions() != b.dimensions() || a.width() < 8 || a.height() < 48 {
        return ScrollAlignment::Unalignable;
    }
    if unchanged(a, b, 0.8) {
        return ScrollAlignment::Duplicate;
    }
    let h = a.height();
    let top = h / 4;
    let bottom = 2.max(h / 20);
    let maxshift = h - top - bottom - 20.max(h / 5);
    if maxshift == 0 {
        return ScrollAlignment::Unalignable;
    }
    let mut candidates: Vec<_> = (1..=maxshift)
        .map(|s| {
            (
                s,
                score(a, b, s, top, bottom, 1.max(a.width() / 32), 1.max(h / 80)),
            )
        })
        .filter(|v| v.1 < 5.)
        .collect();
    candidates.sort_by(|a, b| a.1.total_cmp(&b.1));
    let mut peaks: Vec<(u32, f64)> = vec![];
    for c in candidates {
        if peaks.iter().all(|p| p.0.abs_diff(c.0) > 3) {
            peaks.push(c);
            if peaks.len() == 8 {
                break;
            }
        }
    }
    let mut refined: Vec<(u32, f64)> = vec![];
    for p in peaks {
        let best = ((p.0.saturating_sub(3)).max(1)..=(p.0 + 3).min(maxshift))
            .map(|s| (s, score(a, b, s, top, bottom, 1, 1.max(h / 400))))
            .min_by(|a, b| a.1.total_cmp(&b.1))
            .unwrap();
        if refined.iter().all(|p| p.0.abs_diff(best.0) > 3) {
            refined.push(best)
        }
    }
    refined.sort_by(|a, b| a.1.total_cmp(&b.1));
    let Some(best) = refined.first() else {
        return ScrollAlignment::Unalignable;
    };
    if best.1 > 2.2
        || refined
            .get(1)
            .is_some_and(|p| p.1 <= (best.1 * 1.4).max(best.1 + 0.45))
        || fixed_footer(a, b)
    {
        ScrollAlignment::Unalignable
    } else {
        ScrollAlignment::Shifted { pixels: best.0 }
    }
}
/// Retains the previous accepted viewport; rejected frames never change the composite.
pub struct ScrollStitcher {
    last: RgbaImage,
    composite: RgbaImage,
}
impl ScrollStitcher {
    pub fn new(image: RgbaImage) -> Result<Self, String> {
        if image.width() == 0 || image.height() == 0 {
            return Err("Empty scroll frame".into());
        }
        Ok(Self {
            last: image.clone(),
            composite: image,
        })
    }
    pub fn append(&mut self, next: RgbaImage) -> AppendResult {
        let a = image::DynamicImage::ImageRgba8(self.last.clone()).into_luma8();
        let b = image::DynamicImage::ImageRgba8(next.clone()).into_luma8();
        match align(&a, &b) {
            ScrollAlignment::Duplicate => AppendResult::Unchanged,
            ScrollAlignment::Unalignable => AppendResult::Rejected,
            ScrollAlignment::Shifted { pixels } => {
                let Some(height) = self.composite.height().checked_add(pixels) else {
                    return AppendResult::Rejected;
                };
                let mut composite = RgbaImage::new(next.width(), height);
                imageops::replace(&mut composite, &self.composite, 0, 0);
                let strip =
                    imageops::crop_imm(&next, 0, next.height() - pixels, next.width(), pixels)
                        .to_image();
                imageops::replace(&mut composite, &strip, 0, self.composite.height() as i64);
                self.composite = composite;
                self.last = next;
                AppendResult::Accepted { rows: pixels }
            }
        }
    }
    pub fn preview(&self, max_width: u32, max_height: u32) -> RgbaImage {
        let scale = (max_width as f64 / self.composite.width() as f64)
            .min(max_height as f64 / self.composite.height() as f64)
            .min(1.);
        imageops::resize(
            &self.composite,
            (self.composite.width() as f64 * scale).round().max(1.) as u32,
            (self.composite.height() as f64 * scale).round().max(1.) as u32,
            FilterType::Triangle,
        )
    }
    pub fn finish(self) -> RgbaImage {
        self.composite
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn frame(offset: u32, header: u32, footer: u32) -> GrayImage {
        GrayImage::from_fn(48, 180, |x, y| {
            let row = if y < header || y >= 180 - footer {
                y
            } else {
                y + offset
            };
            image::Luma([(((row as u64 * 1_664_525 + x as u64 * 1_013_904_223)
                ^ (row as u64 * x as u64 * 7_919))
                >> 7) as u8])
        })
    }
    #[test]
    fn swift_vectors() {
        for shift in [1, 37, 90] {
            assert_eq!(
                align(&frame(0, 0, 0), &frame(shift, 0, 0)),
                ScrollAlignment::Shifted { pixels: shift }
            );
        }
        assert_eq!(
            align(&frame(0, 35, 0), &frame(41, 35, 0)),
            ScrollAlignment::Shifted { pixels: 41 }
        );
        for (a, b) in [
            (frame(40, 0, 0), frame(0, 0, 0)),
            (frame(0, 0, 0), frame(240, 0, 0)),
            (frame(0, 0, 15), frame(30, 0, 15)),
        ] {
            assert_eq!(align(&a, &b), ScrollAlignment::Unalignable);
        }
    }
    #[test]
    fn whole_preview_and_seam() {
        let rgb = |f| image::DynamicImage::ImageLuma8(f).into_rgba8();
        let mut s = ScrollStitcher::new(rgb(frame(0, 0, 0))).unwrap();
        assert_eq!(
            s.append(rgb(frame(37, 0, 0))),
            AppendResult::Accepted { rows: 37 }
        );
        assert_eq!(s.preview(100, 100).height(), 100);
        let out = s.finish();
        assert_eq!(out.dimensions(), (48, 217));
        assert_eq!(
            *out.get_pixel(20, 216),
            *rgb(frame(37, 0, 0)).get_pixel(20, 179)
        );
    }
}
#[cfg(test)]
mod additional_tests {
    use super::*;
    #[test]
    fn sparse_swift_fixture() {
        let document = |offset: u32| {
            GrayImage::from_fn(160, 720, |x, y| {
                let value = if y < 90 {
                    if x > 12 && x < 130 && y % 19 < 5 {
                        50
                    } else {
                        240
                    }
                } else if !(10..=148).contains(&x) {
                    255
                } else {
                    let row = y + offset;
                    let line = row / 23;
                    let word = (x / 5 + line * 7) % 13;
                    if row % 23 < 6 && word < line % 8 + 3 {
                        30
                    } else {
                        255
                    }
                };
                image::Luma([value])
            })
        };
        for pixels in [1, 8, 41, 120, 260, 350] {
            assert_eq!(
                align(&document(0), &document(pixels)),
                ScrollAlignment::Shifted { pixels }
            );
        }
    }
    #[test]
    fn repeated_blank_and_resized_frames_reject() {
        let repeat = |offset: u32| {
            GrayImage::from_fn(48, 180, |x, y| {
                image::Luma([(((y + offset) % 12 * 19 + x * 7) % 255) as u8])
            })
        };
        assert_eq!(align(&repeat(0), &repeat(5)), ScrollAlignment::Unalignable);
        assert_eq!(
            align(
                &GrayImage::from_pixel(48, 180, image::Luma([255])),
                &GrayImage::from_pixel(48, 180, image::Luma([230]))
            ),
            ScrollAlignment::Unalignable
        );
        assert_eq!(
            align(&GrayImage::new(48, 180), &GrayImage::new(48, 181)),
            ScrollAlignment::Unalignable
        );
        assert!(!is_stable(&GrayImage::new(0, 0), &GrayImage::new(0, 0)));
    }
}
