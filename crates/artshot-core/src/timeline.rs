use serde::{Deserialize, Serialize};
use std::ops::Range;
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct RecordingCut {
    pub start: f64,
    pub end: f64,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct RecordingEdit {
    pub camera: bool,
    pub system_audio: bool,
    pub microphone: bool,
    pub clicks: bool,
    pub keys: bool,
    pub start: f64,
    pub end: f64,
    pub system_audio_volume: f64,
    pub microphone_volume: f64,
    pub cuts: Vec<RecordingCut>,
}
impl Default for RecordingEdit {
    fn default() -> Self {
        Self {
            camera: true,
            system_audio: true,
            microphone: true,
            clicks: true,
            keys: true,
            start: 0.,
            end: f64::MAX,
            system_audio_volume: 1.,
            microphone_volume: 1.,
            cuts: vec![],
        }
    }
}
pub fn effective_gain(volume: f64) -> f64 {
    if volume.is_finite() {
        volume.clamp(0., 2.)
    } else {
        1.
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TimelineSegment {
    pub source_start: f64,
    pub source_end: f64,
    pub output_start: f64,
}
impl TimelineSegment {
    pub fn duration(self) -> f64 {
        self.source_end - self.source_start
    }
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct EditTimeline {
    pub segments: Vec<TimelineSegment>,
    pub duration: f64,
}
impl EditTimeline {
    pub fn new(duration: f64, edit: &RecordingEdit) -> Result<Self, String> {
        if !duration.is_finite() || duration <= 0. {
            return Err("Invalid source duration".into());
        }
        let start = if edit.start.is_finite() {
            edit.start.max(0.).min(duration)
        } else {
            0.
        };
        let end = if edit.end.is_finite() {
            edit.end.min(duration)
        } else {
            duration
        };
        if end <= start {
            return Err("End must follow start".into());
        }
        let mut cuts: Vec<_> = edit
            .cuts
            .iter()
            .filter(|c| c.start.is_finite() && c.end.is_finite() && c.end > c.start)
            .map(|c| RecordingCut {
                start: c.start.max(start),
                end: c.end.min(end),
            })
            .filter(|c| c.end > c.start)
            .collect();
        cuts.sort_by(|a, b| a.start.total_cmp(&b.start));
        let mut cursor = start;
        let mut output = 0.;
        let mut segments = vec![];
        for cut in cuts {
            if cut.start > cursor {
                segments.push(TimelineSegment {
                    source_start: cursor,
                    source_end: cut.start,
                    output_start: output,
                });
                output += cut.start - cursor;
            }
            cursor = cursor.max(cut.end);
        }
        if cursor < end {
            segments.push(TimelineSegment {
                source_start: cursor,
                source_end: end,
                output_start: output,
            });
            output += end - cursor;
        }
        if output <= 0. {
            return Err("Keep at least one passage".into());
        }
        Ok(Self {
            segments,
            duration: output,
        })
    }
    pub fn source_time(&self, time: f64) -> f64 {
        let t = if time.is_finite() {
            time.clamp(0., self.duration)
        } else {
            0.
        };
        for s in &self.segments {
            if t < s.output_start + s.duration() {
                return s.source_start + (t - s.output_start).max(0.);
            }
        }
        self.segments.last().map_or(0., |s| s.source_end)
    }
    pub fn output_time(&self, time: f64) -> Option<f64> {
        for s in &self.segments {
            if time >= s.source_start && time < s.source_end {
                return Some(s.output_start + time - s.source_start);
            }
        }
        self.segments
            .last()
            .filter(|s| time == s.source_end)
            .map(|_| self.duration)
    }
}
/// Host-clock seconds; presentation timestamps remain in the original host domain.
#[derive(Clone, Debug, Default)]
pub struct RecordingTimeline {
    origin: Option<f64>,
    stopped: Option<f64>,
    pauses: Vec<(f64, Option<f64>)>,
}
impl RecordingTimeline {
    pub fn begin(&mut self, time: f64) {
        if time.is_finite() && self.origin.is_none() {
            self.origin = Some(time)
        }
    }
    pub fn is_paused(&self) -> bool {
        self.pauses.last().is_some_and(|p| p.1.is_none())
    }
    pub fn set_paused(&mut self, paused: bool, time: f64) {
        if !time.is_finite() || self.stopped.is_some() || paused == self.is_paused() {
            return;
        }
        let time = time
            .max(self.origin.unwrap_or(time))
            .max(self.pauses.last().map_or(time, |p| p.1.unwrap_or(p.0)));
        if paused {
            self.pauses.push((time, None))
        } else {
            self.pauses.last_mut().unwrap().1 = Some(time)
        }
    }
    pub fn stop(&mut self, time: f64) {
        if time.is_finite() {
            self.stopped = Some(time)
        }
    }
    pub fn paused_at(&self, time: f64) -> bool {
        self.pauses
            .iter()
            .any(|p| time >= p.0 && p.1.is_none_or(|end| time < end))
    }
    fn excluded(&self, time: f64) -> f64 {
        let Some(origin) = self.origin else { return 0. };
        self.pauses
            .iter()
            .map(|p| (time.min(p.1.unwrap_or(time)) - origin.max(p.0)).max(0.))
            .sum()
    }
    pub fn presentation_time(&self, time: f64) -> Option<f64> {
        let origin = self.origin?;
        if !time.is_finite()
            || time < origin
            || self.paused_at(time)
            || self.stopped.is_some_and(|s| time > s)
        {
            None
        } else {
            Some(time - self.excluded(time))
        }
    }
    pub fn elapsed(&self, time: f64) -> f64 {
        let Some(origin) = self.origin else { return 0. };
        if !time.is_finite() {
            return 0.;
        }
        let end = time.min(self.stopped.unwrap_or(time));
        (end - origin - self.excluded(end)).max(0.)
    }
    pub fn audio_sample_ranges(
        &self,
        start: f64,
        count: usize,
        sample_rate: f64,
    ) -> Vec<Range<usize>> {
        let Some(origin) = self.origin else {
            return vec![];
        };
        if count == 0 || !start.is_finite() || !sample_rate.is_finite() || sample_rate <= 0. {
            return vec![];
        }
        let end = start + count as f64 / sample_rate;
        let mut intervals = vec![(start.max(origin), end.min(self.stopped.unwrap_or(end)))];
        for p in &self.pauses {
            let pe = p.1.unwrap_or(end);
            intervals = intervals
                .into_iter()
                .flat_map(|(a, b)| {
                    if p.0 >= b || pe <= a {
                        return vec![(a, b)];
                    }
                    let mut out = vec![];
                    if a < p.0 {
                        out.push((a, b.min(p.0)))
                    }
                    if pe < b {
                        out.push((a.max(pe), b))
                    }
                    out
                })
                .collect();
        }
        intervals
            .into_iter()
            .filter_map(|(a, b)| {
                let lo = (((a - start) * sample_rate - 0.0001).ceil().max(0.) as usize).min(count);
                let hi = (((b - start) * sample_rate + 0.0001).floor().max(0.) as usize).min(count);
                (hi > lo).then_some(lo..hi)
            })
            .collect()
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn overlapping_cuts() {
        let edit = RecordingEdit {
            start: 1.,
            end: 9.,
            cuts: vec![
                RecordingCut { start: 3., end: 5. },
                RecordingCut { start: 4., end: 7. },
            ],
            ..Default::default()
        };
        let t = EditTimeline::new(10., &edit).unwrap();
        assert_eq!(t.duration, 4.);
        assert_eq!(t.source_time(2.), 7.);
        assert_eq!(t.output_time(5.), None);
        assert_eq!(t.output_time(9.), Some(4.));
    }
    #[test]
    fn late_audio_drops_historical_pauses() {
        let mut t = RecordingTimeline::default();
        t.begin(100.);
        t.set_paused(true, 101.);
        t.set_paused(false, 102.);
        t.stop(104.);
        assert_eq!(t.audio_sample_ranges(100., 50, 10.), vec![0..10, 20..40]);
        assert_eq!(t.presentation_time(102.), Some(101.));
        assert_eq!(t.presentation_time(101.5), None);
        assert_eq!(t.elapsed(110.), 3.);
    }
}
