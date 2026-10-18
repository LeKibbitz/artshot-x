use crate::{
    backend::{atomic_json, err, Backend},
    model::*,
    windows,
};
use base64::Engine;
use serde_json::Value;
use std::{
    path::{Path, PathBuf},
    sync::Mutex,
    time::Duration,
};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_clipboard_manager::ClipboardExt;
use tauri_plugin_dialog::DialogExt;
pub type Store = Mutex<Backend>;
fn selection_keys(app: &AppHandle, enable: bool) {
    #[cfg(target_os = "windows")]
    {
        use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Shortcut};
        for code in [Code::Enter, Code::Escape] {
            let key = Shortcut::new(None, code);
            let result = if enable {
                app.global_shortcut().register(key)
            } else {
                app.global_shortcut().unregister(key)
            };
            if let Err(e) = result {
                if enable {
                    if let Ok(mut b) = app.state::<Store>().lock() {
                        b.state.shortcut_errors.push(e.to_string());
                    }
                }
            }
        }
    }
    #[cfg(not(target_os = "windows"))]
    let _ = (app, enable);
}
pub fn emit(app: &AppHandle) {
    if let Ok(b) = app.state::<Store>().lock() {
        let _ = app.emit("app-state", b.snapshot());
    }
}
pub fn error(app: &AppHandle, error: String) {
    if let Ok(mut b) = app.state::<Store>().lock() {
        b.state.error = Some(error);
    }
    emit(app);
    if let Ok(d) = current_display(app) {
        let _ = windows::floating(app, "quick", &d, 360., 300.);
    }
}
pub async fn work<T: Send + 'static>(
    app: AppHandle,
    f: impl FnOnce(&mut Backend) -> Result<T, String> + Send + 'static,
) -> Result<T, String> {
    let a = app.clone();
    let result = tauri::async_runtime::spawn_blocking(move || {
        let state = a.state::<Store>();
        let mut b = state.lock().map_err(err)?;
        b.state.error = None;
        f(&mut b)
    })
    .await
    .map_err(err)?;
    if let Err(e) = &result {
        error(&app, e.clone())
    } else {
        emit(&app)
    }
    result
}
#[tauri::command]
pub fn get_state(app: AppHandle) -> Result<AppState, String> {
    Ok(app.state::<Store>().lock().map_err(err)?.snapshot())
}
fn current_display(app: &AppHandle) -> Result<artshot_platform::Display, String> {
    let displays = artshot_platform::list_displays().map_err(err)?;
    #[cfg(target_os = "macos")]
    {
        let current = app
            .state::<Store>()
            .lock()
            .map_err(err)?
            .bridge()?
            .request(serde_json::json!({"action":"current_display"}))
            .map_err(err)?;
        if let Some(id) = current["displayId"].as_u64() {
            if let Some(d) = displays.iter().find(|d| d.id == id as u32) {
                return Ok(d.clone());
            }
        }
    }
    let cursor = app
        .get_webview_window("main")
        .and_then(|w| w.cursor_position().ok());
    let found = cursor.and_then(|p| {
        displays
            .iter()
            .find(|d| {
                #[cfg(target_os = "macos")]
                let (x, y) = (p.x / d.scale_factor as f64, p.y / d.scale_factor as f64);
                #[cfg(not(target_os = "macos"))]
                let (x, y) = (p.x, p.y);
                let scale = if cfg!(target_os = "macos") {
                    d.scale_factor as f64
                } else {
                    1.
                };
                x >= d.x as f64
                    && y >= d.y as f64
                    && x < (d.x as f64 + d.width as f64 / scale)
                    && y < (d.y as f64 + d.height as f64 / scale)
            })
            .cloned()
    });
    found
        .or_else(|| displays.into_iter().next())
        .ok_or("Aucun écran disponible".into())
}
#[tauri::command]
pub async fn begin_selection(app: AppHandle, mode: Option<String>) -> Result<(), String> {
    if app
        .state::<Store>()
        .lock()
        .map_err(err)?
        .state
        .recording
        .is_some()
    {
        windows::show(&app, "recording");
        return Ok(());
    }
    windows::hide_overlays(&app);
    if let Some(main) = app.get_webview_window("main") {
        let _ = main.hide();
    }
    let d = current_display(&app)?;
    let copy = d.clone();
    work(app.clone(), move |b| {
        b.prepare(copy, mode.unwrap_or("menu".into()))
    })
    .await?;
    windows::selection(&app, &d)?;
    selection_keys(&app, true);
    emit(&app);
    Ok(())
}
#[tauri::command]
pub async fn set_selection(app: AppHandle, rect: Rect) -> Result<(), String> {
    work(app, move |b| {
        let d = b.display.as_ref().ok_or("Aucun écran")?;
        rect.region(d)?;
        b.state.selection = Some(rect);
        Ok(())
    })
    .await
}
#[tauri::command]
pub async fn capture_fullscreen(app: AppHandle) -> Result<(), String> {
    windows::hide_overlays(&app);
    if let Some(main) = app.get_webview_window("main") {
        let _ = main.hide();
    }
    let d = current_display(&app)?;
    let copy = d.clone();
    work(app.clone(), move |b| {
        b.ensure_idle()?;
        b.stop_preview()?;
        let image = b.frame(&copy, None)?;
        b.display = Some(copy);
        b.add_image(image)?;
        Ok(())
    })
    .await?;
    windows::floating(&app, "quick", &d, 340., 260.)?;
    emit(&app);
    Ok(())
}
#[tauri::command]
pub async fn capture_photo(app: AppHandle) -> Result<(), String> {
    selection_keys(&app, false);
    windows::hide(&app, "selection");
    let d = work(app.clone(), |b| {
        b.ensure_idle()?;
        b.stop_preview()?;
        let (d, r) = b.target()?;
        let image = b.frame(&d, r)?;
        b.add_image(image)?;
        Ok(d)
    })
    .await?;
    windows::floating(&app, "quick", &d, 340., 260.)?;
    emit(&app);
    Ok(())
}
#[tauri::command]
pub async fn start_scroll(app: AppHandle) -> Result<(), String> {
    selection_keys(&app, false);
    windows::hide(&app, "selection");
    let (d, epoch) = work(app.clone(), |b| {
        b.stop_preview()?;
        b.start_scroll()?;
        Ok((b.target()?.0, b.scroll_epoch))
    })
    .await?;
    windows::floating(&app, "scrolling", &d, 350., 600.)?;
    emit(&app);
    let a = app.clone();
    tauri::async_runtime::spawn_blocking(move || loop {
        std::thread::sleep(Duration::from_millis(400));
        let result = {
            let s = a.state::<Store>();
            let mut b = match s.lock() {
                Ok(b) => b,
                Err(_) => break,
            };
            if b.scroll_epoch != epoch || b.stitcher.is_none() {
                break;
            }
            b.poll_scroll()
        };
        if let Err(e) = result {
            error(&a, e);
            break;
        }
        emit(&a);
    });
    Ok(())
}
#[tauri::command]
pub async fn finish_scroll(app: AppHandle) -> Result<(), String> {
    let d = work(app.clone(), |b| {
        b.poll_scroll()?;
        std::thread::sleep(Duration::from_millis(200));
        b.poll_scroll()?;
        b.finish_scroll()?;
        Ok(b.target()?.0)
    })
    .await?;
    windows::hide(&app, "scrolling");
    windows::floating(&app, "quick", &d, 340., 260.)?;
    emit(&app);
    Ok(())
}
#[tauri::command]
pub async fn close_overlay(app: AppHandle) -> Result<(), String> {
    selection_keys(&app, false);
    windows::hide_overlays(&app);
    work(app, |b| {
        b.stop_preview()?;
        b.stitcher = None;
        b.previous_frame = None;
        b.scroll_epoch += 1;
        b.state.scrolling = None;
        b.state.selection = None;
        b.state.selection_display = None;
        Ok(())
    })
    .await
}
#[tauri::command]
pub async fn start_recording(app: AppHandle, options: RecordingOptions) -> Result<(), String> {
    selection_keys(&app, false);
    windows::hide_overlays(&app);
    let d = work(app.clone(), move |b| {
        #[cfg(target_os = "windows")]
        let mut options = options;
        #[cfg(target_os = "windows")]
        if b.state.settings["cameraPreviewPath"].is_string() {
            options.camera_x = b.state.settings["cameraX"]
                .as_f64()
                .unwrap_or(options.camera_x);
            options.camera_y = b.state.settings["cameraY"]
                .as_f64()
                .unwrap_or(options.camera_y);
        }
        b.start_recording(options)?;
        Ok(b.target()?.0)
    })
    .await?;
    windows::floating(&app, "recording", &d, 550., 90.)?;
    #[cfg(target_os = "windows")]
    {
        let camera = {
            let s = app.state::<Store>();
            let mut b = s.lock().map_err(err)?;
            let path = b.recorder.as_ref().and_then(|r| r.camera_preview_path());
            if let Some(p) = &path {
                b.state.settings["cameraPreviewPath"] = serde_json::json!(p);
            }
            path
        };
        if camera.is_some() {
            show_camera_preview(&app)?;
        }
    }
    emit(&app);
    Ok(())
}
#[tauri::command]
pub async fn recording_action(app: AppHandle, action: String) -> Result<(), String> {
    match action.as_str() {
        "pause" | "resume" => {
            work(app.clone(), move |b| b.pause_recording(action == "pause")).await?;
        }
        "stop" | "delete" | "restart" => {
            let restart = action == "restart";
            let discard = action == "delete";
            let (d, options) = work(app.clone(), move |b| {
                let options = b.record_options.clone();
                b.stop_recording(discard)?;
                Ok((b.target()?.0, options))
            })
            .await?;
            windows::hide(&app, "recording");
            windows::hide(&app, "camera");
            if restart {
                start_recording(app.clone(), options.ok_or("Options manquantes")?).await?;
            } else if !discard {
                windows::floating(&app, "quick", &d, 340., 260.)?;
            }
        }
        _ => return Err("Commande d’enregistrement inconnue".into()),
    }
    emit(&app);
    Ok(())
}
#[tauri::command]
pub async fn update_settings(app: AppHandle, settings: Value) -> Result<(), String> {
    work(app.clone(), move |b| {
        if b.state.recording.is_some() {
            return Err("Réglages verrouillés pendant l’enregistrement".into());
        }
        #[cfg(target_os = "windows")]
        let mut settings = settings;
        #[cfg(target_os = "windows")]
        if b.state.settings["cameraPreviewPath"].is_string() {
            for key in ["cameraX", "cameraY"] {
                settings[key] = b.state.settings[key].clone();
            }
        }
        b.update_camera_preview(settings)?;
        atomic_json(&b.root.join("settings.json"), &b.state.settings)
    })
    .await?;
    #[cfg(target_os = "windows")]
    {
        show_camera_preview(&app)?;
    }
    Ok(())
}
#[tauri::command]
pub async fn open_editor(app: AppHandle, id: String) -> Result<(), String> {
    work(app.clone(), move |b| {
        b.item(&id)?;
        b.state.active_item_id = Some(id);
        Ok(())
    })
    .await?;
    windows::hide(&app, "quick");
    windows::main(&app);
    Ok(())
}
#[tauri::command]
pub async fn delete_item(app: AppHandle, id: String) -> Result<(), String> {
    work(app.clone(), move |b| {
        let item = b.item(&id)?;
        let path = Path::new(item.original_path.as_ref().unwrap_or(&item.path));
        let path = if item.kind == "video" {
            path.parent().ok_or("Dossier invalide")?
        } else {
            path
        };
        let canonical = path.canonicalize().map_err(err)?;
        if !canonical.starts_with(b.root.canonicalize().map_err(err)?) {
            return Err("Suppression hors bibliothèque refusée".into());
        }
        trash::delete(canonical).map_err(err)?;
        b.state.library.retain(|i| i.id != id);
        b.state.active_item_id = None;
        b.save()
    })
    .await?;
    windows::hide(&app, "quick");
    Ok(())
}
async fn destination(app: &AppHandle, name: &str, ext: &str) -> Result<Option<PathBuf>, String> {
    let dialog = app
        .dialog()
        .file()
        .set_file_name(name)
        .add_filter(ext, &[ext]);
    tauri::async_runtime::spawn_blocking(move || {
        dialog
            .blocking_save_file()
            .map(|p| p.into_path().map_err(err))
            .transpose()
    })
    .await
    .map_err(err)?
}
fn protected_media_paths(items: &[MediaItem]) -> Vec<PathBuf> {
    items
        .iter()
        .flat_map(|item| {
            let mut paths = vec![PathBuf::from(&item.path)];
            if let Some(path) = &item.original_path {
                paths.push(PathBuf::from(path));
            }
            paths.extend(item.system_wav.iter().cloned());
            paths.extend(item.microphone_wav.iter().cloned());
            paths
        })
        .collect()
}
fn resolved_destination(path: &Path) -> Result<PathBuf, String> {
    if path.exists() {
        return std::fs::canonicalize(path).map_err(err);
    }
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let name = path.file_name().ok_or("Nom de fichier invalide")?;
    Ok(std::fs::canonicalize(parent).map_err(err)?.join(name))
}
fn ensure_export_destination(path: &Path, protected: &[PathBuf]) -> Result<(), String> {
    let destination = resolved_destination(path)?;
    for source in protected {
        if !source.exists() {
            continue;
        }
        let original = std::fs::canonicalize(source).map_err(err)?;
        if destination == original
            || (path.exists() && same_file::is_same_file(path, source).map_err(err)?)
        {
            return Err("Choisissez une copie distincte des captures et de leurs originaux".into());
        }
    }
    if path.is_dir() {
        return Err("La destination doit être un fichier".into());
    }
    Ok(())
}
/// Render into a new sibling, then replace only after a complete successful
/// export. Failure removes only this operation's temporary file.
fn transactional_export(
    path: &Path,
    protected: &[PathBuf],
    extension: &str,
    write: impl FnOnce(&Path) -> Result<(), String>,
) -> Result<(), String> {
    ensure_export_destination(path, protected)?;
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let temporary = parent.join(format!(
        ".artshot-export-{}.{}",
        uuid::Uuid::new_v4(),
        extension
    ));
    if temporary.exists() {
        return Err("Impossible de réserver le fichier temporaire".into());
    }
    let result = (|| {
        write(&temporary)?;
        std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&temporary)
            .and_then(|file| file.sync_all())
            .map_err(err)?;
        ensure_export_destination(path, protected)?;
        #[cfg(target_os = "windows")]
        {
            use ::windows::Win32::Storage::FileSystem::{
                MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
            };
            use std::os::windows::ffi::OsStrExt;
            let from: Vec<u16> = temporary.as_os_str().encode_wide().chain(Some(0)).collect();
            let to: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
            unsafe {
                MoveFileExW(
                    ::windows::core::PCWSTR(from.as_ptr()),
                    ::windows::core::PCWSTR(to.as_ptr()),
                    MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
                )
            }
            .map_err(err)?;
        }
        #[cfg(not(target_os = "windows"))]
        std::fs::rename(&temporary, path).map_err(err)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}
fn image_item(item: &MediaItem) -> Result<(), String> {
    if item.kind != "image" {
        return Err("Cette action concerne uniquement les images".into());
    }
    Ok(())
}
#[tauri::command]
pub async fn save_item(app: AppHandle, id: String) -> Result<(), String> {
    let item = app.state::<Store>().lock().map_err(err)?.item(&id)?;
    let extension = match item.kind.as_str() {
        "image" => "png",
        "video" => "mp4",
        _ => return Err("Type de capture incompatible".into()),
    };
    let Some(path) = destination(&app, &format!("{}.{}", item.name, extension), extension).await?
    else {
        return Ok(());
    };
    work(app, move |backend| {
        let protected = protected_media_paths(&backend.state.library);
        transactional_export(&path, &protected, extension, |temporary| {
            if item.kind == "video" {
                backend.export_video(&item, temporary, vec![], 1., 1.)
            } else {
                image::open(&item.path)
                    .map_err(err)?
                    .save_with_format(temporary, image::ImageFormat::Png)
                    .map_err(err)
            }
        })
    })
    .await
}
fn decode_image(data_url: &str) -> Result<image::RgbaImage, String> {
    if data_url.len() > 180_000_000 {
        return Err("Image trop volumineuse".into());
    }
    let value = data_url
        .strip_prefix("data:image/png;base64,")
        .ok_or("Format PNG attendu")?;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(value)
        .map_err(err)?;
    let mut reader =
        image::ImageReader::with_format(std::io::Cursor::new(bytes), image::ImageFormat::Png);
    let mut limits = image::Limits::default();
    limits.max_alloc = Some(256 * 1024 * 1024);
    reader.limits(limits);
    Ok(reader.decode().map_err(err)?.into_rgba8())
}
fn exact_image(item: &MediaItem, data_url: &str) -> Result<image::RgbaImage, String> {
    image_item(item)?;
    let image = decode_image(data_url)?;
    if image.dimensions() != (item.width, item.height) {
        return Err("L’export doit conserver la résolution d’origine".into());
    }
    Ok(image)
}
#[tauri::command]
pub async fn copy_image(
    app: AppHandle,
    id: String,
    data_url: Option<String>,
) -> Result<(), String> {
    let item = app.state::<Store>().lock().map_err(err)?.item(&id)?;
    image_item(&item)?;
    let image = if let Some(data) = data_url {
        exact_image(&item, &data)?
    } else {
        image::open(item.path).map_err(err)?.into_rgba8()
    };
    let (width, height) = image.dimensions();
    app.clipboard()
        .write_image(&tauri::image::Image::new_owned(
            image.into_raw(),
            width,
            height,
        ))
        .map_err(err)
}
#[tauri::command]
pub async fn export_image(app: AppHandle, id: String, data_url: String) -> Result<(), String> {
    let item = app.state::<Store>().lock().map_err(err)?.item(&id)?;
    image_item(&item)?;
    let Some(path) = destination(&app, &format!("{}-annotee.png", item.name), "png").await? else {
        return Ok(());
    };
    work(app, move |backend| {
        let image = exact_image(&item, &data_url)?;
        let protected = protected_media_paths(&backend.state.library);
        transactional_export(&path, &protected, "png", |temporary| {
            image
                .save_with_format(temporary, image::ImageFormat::Png)
                .map_err(err)
        })
    })
    .await
}
#[tauri::command]
pub async fn export_video(
    app: AppHandle,
    id: String,
    cuts: Vec<Value>,
    microphone_gain: f64,
    system_gain: f64,
    camera: Option<bool>,
    clicks: Option<bool>,
    keys: Option<bool>,
) -> Result<(), String> {
    let mut item = app.state::<Store>().lock().map_err(err)?.item(&id)?;
    edit_effects(&mut item, camera, clicks, keys);
    if item.kind != "video" {
        return Err("Cette action concerne uniquement les vidéos".into());
    }
    let Some(path) = destination(&app, &format!("{}-montage.mp4", item.name), "mp4").await? else {
        return Ok(());
    };
    work(app, move |backend| {
        let protected = protected_media_paths(&backend.state.library);
        transactional_export(&path, &protected, "mp4", |temporary| {
            backend.export_video(&item, temporary, cuts, microphone_gain, system_gain)
        })
    })
    .await
}
#[tauri::command]
pub async fn save_image_edits(
    app: AppHandle,
    id: String,
    annotations: Value,
) -> Result<(), String> {
    work(app, move |backend| {
        let item = backend.item(&id)?;
        image_item(&item)?;
        let id = uuid::Uuid::parse_str(&item.id)
            .map_err(|_| "Identifiant de capture invalide".to_owned())?;
        if !annotations.is_array()
            || serde_json::to_vec(&annotations).map_err(err)?.len() > 1_048_576
        {
            return Err("Annotations invalides ou trop volumineuses".into());
        }
        atomic_json(
            &backend
                .root
                .join("captures")
                .join(format!("{id}.edits.json")),
            &annotations,
        )
    })
    .await
}
#[cfg(test)]
mod export_tests {
    use super::*;
    fn directory() -> PathBuf {
        let path =
            std::env::temp_dir().join(format!("artshot-export-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&path).unwrap();
        path
    }
    fn item(path: &Path) -> MediaItem {
        MediaItem {
            id: uuid::Uuid::new_v4().to_string(),
            name: "Test".into(),
            kind: "image".into(),
            path: path.to_string_lossy().into_owned(),
            created_at: String::new(),
            width: 3,
            height: 2,
            duration: None,
            original_path: None,
            recording_options: Value::Null,
            system_wav: None,
            microphone_wav: None,
        }
    }
    #[test]
    fn protects_original_aliases_and_hardlinks() {
        let root = directory();
        let original = root.join("original.png");
        std::fs::write(&original, b"immutable").unwrap();
        let protected = vec![original.clone()];
        let hardlink = root.join("hardlink.png");
        std::fs::hard_link(&original, &hardlink).unwrap();
        assert!(ensure_export_destination(&hardlink, &protected).is_err());
        assert!(ensure_export_destination(&root.join("./original.png"), &protected).is_err());
        #[cfg(unix)]
        {
            let symlink = root.join("symbolic.png");
            std::os::unix::fs::symlink(&original, &symlink).unwrap();
            assert!(ensure_export_destination(&symlink, &protected).is_err());
        }
        assert!(ensure_export_destination(&root.join("copy.png"), &protected).is_ok());
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn failed_export_keeps_existing_user_file() {
        let root = directory();
        let path = root.join("chosen.mp4");
        std::fs::write(&path, b"existing user export").unwrap();
        let result = transactional_export(&path, &[], "mp4", |temp| {
            assert!(!temp.exists());
            std::fs::write(temp, b"partial").unwrap();
            Err("injected export failure".into())
        });
        assert!(result.is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"existing user export");
        assert_eq!(std::fs::read_dir(&root).unwrap().count(), 1);
        transactional_export(&path, &[], "mp4", |temp| {
            std::fs::write(temp, b"complete").map_err(err)
        })
        .unwrap();
        assert_eq!(std::fs::read(path).unwrap(), b"complete");
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn png_dimensions_and_media_kind_are_checked() {
        let image = image::RgbaImage::new(3, 2);
        let mut bytes = std::io::Cursor::new(vec![]);
        image.write_to(&mut bytes, image::ImageFormat::Png).unwrap();
        let data = format!(
            "data:image/png;base64,{}",
            base64::engine::general_purpose::STANDARD.encode(bytes.into_inner())
        );
        let mut item = item(Path::new("unused.png"));
        assert_eq!(exact_image(&item, &data).unwrap().dimensions(), (3, 2));
        item.width = 4;
        assert!(exact_image(&item, &data).is_err());
        item.width = 3;
        item.kind = "video".into();
        assert!(exact_image(&item, &data).is_err());
        assert!(decode_image("data:image/jpeg;base64,AA==").is_err());
    }
}
#[cfg(target_os = "windows")]
fn show_camera_preview(app: &AppHandle) -> Result<(), String> {
    let (d, r, settings) = {
        let s = app.state::<Store>();
        let b = s.lock().map_err(err)?;
        let (d, r) = b.target()?;
        (d, r, b.state.settings.clone())
    };
    if settings["cameraPreviewPath"].as_str().is_none() {
        windows::hide(app, "camera");
        return Ok(());
    }
    let region = r.unwrap_or(artshot_platform::Region {
        x: 0,
        y: 0,
        width: d.width,
        height: d.height,
    });
    let mut width = region.width as f64 * settings["cameraSize"].as_f64().unwrap_or(24.) / 100.;
    let mut height = width
        * match settings["cameraShape"].as_str() {
            Some("verticalOval") => 4. / 3.,
            Some("rounded") | Some("roundedRectangle") => 0.75,
            _ => 1.,
        };
    if height > region.height as f64 {
        width *= region.height as f64 / height;
        height = region.height as f64;
    }
    let w = windows::create(
        app,
        "camera",
        width / d.scale_factor as f64,
        height / d.scale_factor as f64,
    )?;
    w.set_size(tauri::PhysicalSize::new(width as u32, height as u32))
        .map_err(err)?;
    let x = d.x
        + region.x
        + (region.width as f64 * settings["cameraX"].as_f64().unwrap_or(0.78) - width / 2.) as i32;
    let y = d.y
        + region.y
        + (region.height as f64 * settings["cameraY"].as_f64().unwrap_or(0.68) - height / 2.)
            as i32;
    let x = x.clamp(
        d.x + region.x,
        d.x + region.x + region.width as i32 - width as i32,
    );
    let y = y.clamp(
        d.y + region.y,
        d.y + region.y + region.height as i32 - height as i32,
    );
    w.set_position(tauri::PhysicalPosition::new(x, y))
        .map_err(err)?;
    windows::show(app, "camera");
    Ok(())
}

fn edit_effects(
    item: &mut MediaItem,
    camera: Option<bool>,
    clicks: Option<bool>,
    keys: Option<bool>,
) {
    for (key, value) in [("camera", camera), ("clicks", clicks), ("keystrokes", keys)] {
        if let Some(v) = value {
            let captured = item.recording_options[key].as_bool().unwrap_or(false);
            item.recording_options[key] = serde_json::json!(captured && v);
        }
    }
}
#[tauri::command]
pub async fn preview_video(
    app: AppHandle,
    id: String,
    cuts: Vec<Value>,
    microphone_gain: f64,
    system_gain: f64,
    camera: Option<bool>,
    clicks: Option<bool>,
    keys: Option<bool>,
) -> Result<String, String> {
    work(app, move |b| {
        let mut item = b.item(&id)?;
        if item.kind != "video" {
            return Err("Vidéo attendue".into());
        }
        edit_effects(&mut item, camera, clicks, keys);
        let path = b
            .root
            .join("cache")
            .join(format!("edit-{}.mp4", uuid::Uuid::new_v4()));
        b.export_video(&item, &path, cuts, microphone_gain, system_gain)?;
        Ok(path.to_string_lossy().into())
    })
    .await
}
#[tauri::command]
pub async fn camera_position(app: AppHandle) -> Result<(), String> {
    #[cfg(target_os = "windows")]
    {
        let w = app
            .get_webview_window("camera")
            .ok_or("Aperçu caméra fermé")?;
        let p = w.outer_position().map_err(err)?;
        let size = w.inner_size().map_err(err)?;
        work(app.clone(), move |b| {
            if b.state.recording.is_some() {
                return Err("Position verrouillée pendant la prise".into());
            }
            let (d, r) = b.target()?;
            let r = r.unwrap_or(artshot_platform::Region {
                x: 0,
                y: 0,
                width: d.width,
                height: d.height,
            });
            b.state.settings["cameraX"] = serde_json::json!(
                ((p.x - d.x - r.x) as f64 + size.width as f64 / 2.) / r.width as f64
            );
            b.state.settings["cameraY"] = serde_json::json!(
                ((p.y - d.y - r.y) as f64 + size.height as f64 / 2.) / r.height as f64
            );
            atomic_json(&b.root.join("settings.json"), &b.state.settings)
        })
        .await?;
        show_camera_preview(&app)?;
    }
    #[cfg(not(target_os = "windows"))]
    let _ = app;
    Ok(())
}

#[tauri::command]
pub fn open_permissions(app: AppHandle) -> Result<(), String> {
    use tauri_plugin_opener::OpenerExt;
    #[cfg(target_os = "macos")]
    let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture";
    #[cfg(target_os = "windows")]
    let url = "ms-settings:privacy";
    app.opener().open_url(url, None::<&str>).map_err(err)
}
#[tauri::command]
pub fn dismiss_error(app: AppHandle) -> Result<(), String> {
    app.state::<Store>().lock().map_err(err)?.state.error = None;
    windows::hide(&app, "quick");
    emit(&app);
    Ok(())
}
