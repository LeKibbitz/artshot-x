//! Opt-in click and shortcut monitoring. Ordinary typing is never recorded.
use serde::{Deserialize, Serialize};
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};
use windows::Win32::{
    Foundation::POINT,
    UI::{Input::KeyboardAndMouse::GetAsyncKeyState, WindowsAndMessaging::GetCursorPos},
};
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Event {
    pub time: f64,
    pub x: Option<f64>,
    pub y: Option<f64>,
    pub label: Option<String>,
}
struct State {
    started: Option<Instant>,
    elapsed: f64,
    events: Vec<Event>,
}
pub struct EventRecorder {
    state: Arc<Mutex<State>>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}
impl EventRecorder {
    pub fn start(region: crate::Region, clicks: bool, keys: bool) -> Self {
        let state = Arc::new(Mutex::new(State {
            started: None,
            elapsed: 0.,
            events: vec![],
        }));
        let stop = Arc::new(AtomicBool::new(false));
        let data = state.clone();
        let flag = stop.clone();
        let thread = thread::spawn(move || {
            let mut previous = [false; 256];
            while !flag.load(Ordering::Relaxed) {
                let mut down = [false; 256];
                for (key, pressed) in down.iter_mut().enumerate() {
                    *pressed = unsafe { GetAsyncKeyState(key as i32) } < 0;
                }
                let mut state = data.lock().unwrap();
                if let Some(started) = state.started {
                    let time = state.elapsed + started.elapsed().as_secs_f64();
                    if clicks {
                        for key in [1, 2] {
                            if down[key] && !previous[key] {
                                let mut p = POINT::default();
                                if unsafe { GetCursorPos(&mut p) }.is_ok() {
                                    let x = (p.x - region.x) as f64 / region.width as f64;
                                    let y = (p.y - region.y) as f64 / region.height as f64;
                                    if (0.0..=1.0).contains(&x) && (0.0..=1.0).contains(&y) {
                                        state.events.push(Event {
                                            time,
                                            x: Some(x),
                                            y: Some(y),
                                            label: None,
                                        });
                                    }
                                }
                            }
                        }
                    }
                    if keys {
                        for key in 8..256 {
                            if down[key] && !previous[key] {
                                let name = match key {
                                    8 => Some("Backspace".into()),
                                    9 => Some("Tab".into()),
                                    13 => Some("Enter".into()),
                                    27 => Some("Esc".into()),
                                    33 => Some("PageUp".into()),
                                    34 => Some("PageDown".into()),
                                    35 => Some("End".into()),
                                    36 => Some("Home".into()),
                                    37 => Some("Left".into()),
                                    38 => Some("Up".into()),
                                    39 => Some("Right".into()),
                                    40 => Some("Down".into()),
                                    46 => Some("Delete".into()),
                                    112..=123 => Some(format!("F{}", key - 111)),
                                    48..=90 if down[17] || down[18] || down[91] || down[92] => {
                                        Some((key as u8 as char).to_string())
                                    }
                                    _ => None,
                                };
                                if let Some(name) = name {
                                    let mut prefix = String::new();
                                    for (pressed, label) in [
                                        (down[17], "Ctrl+"),
                                        (down[18], "Alt+"),
                                        (down[16], "Shift+"),
                                        (down[91] || down[92], "Win+"),
                                    ] {
                                        if pressed {
                                            prefix.push_str(label)
                                        }
                                    }
                                    state.events.push(Event {
                                        time,
                                        x: None,
                                        y: None,
                                        label: Some(prefix + &name),
                                    });
                                }
                            }
                        }
                    }
                }
                drop(state);
                previous = down;
                thread::sleep(Duration::from_millis(8));
            }
        });
        Self {
            state,
            stop,
            thread: Some(thread),
        }
    }
    pub fn resume_at(&self, media_time: f64) {
        let mut state = self.state.lock().unwrap();
        state.elapsed = media_time;
        state.started = Some(Instant::now());
    }
    pub fn resume(&self) {
        let mut s = self.state.lock().unwrap();
        if s.started.is_none() {
            s.started = Some(Instant::now());
        }
    }
    pub fn pause(&self) {
        let mut s = self.state.lock().unwrap();
        if let Some(t) = s.started.take() {
            s.elapsed += t.elapsed().as_secs_f64();
        }
    }
    pub fn finish(&mut self) -> Vec<Event> {
        self.pause();
        self.stop.store(true, Ordering::Relaxed);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
        self.state.lock().unwrap().events.clone()
    }
}
impl Drop for EventRecorder {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}
