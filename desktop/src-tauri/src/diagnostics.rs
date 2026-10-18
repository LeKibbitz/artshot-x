use std::{fs::OpenOptions, io::Write, sync::Mutex};
use tauri::Manager;

static WRITE_LOCK: Mutex<()> = Mutex::new(());

/// Only our registered shortcuts and window lifecycle are recorded. Never log
/// arbitrary keys, screen contents, file names, or the user's other applications.
pub fn record(app: &tauri::AppHandle, message: &str) {
    let Ok(_guard) = WRITE_LOCK.lock() else {
        return;
    };
    let Ok(root) = app.path().app_data_dir() else {
        return;
    };
    let path = root.join("capture-diagnostics.log");
    if std::fs::metadata(&path).is_ok_and(|m| m.len() > 256 * 1024) {
        let _ = std::fs::rename(&path, root.join("capture-diagnostics.previous.log"));
    }
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{} {}", chrono::Utc::now().to_rfc3339(), message);
    }
}
