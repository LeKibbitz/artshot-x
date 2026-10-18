mod backend;
mod commands;
mod diagnostics;
mod model;
mod windows;
use commands::*;
use std::sync::Mutex;
use tauri::{
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    Manager,
};
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};

pub fn run() {
    let builder = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| {
            windows::main(app)
        }))
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, shortcut, event| {
                    diagnostics::record(
                        app,
                        &format!("shortcut {:?} {:?}", shortcut.key, event.state),
                    );
                    if event.state != ShortcutState::Pressed {
                        return;
                    }
                    let app = app.clone();
                    let digit = if shortcut.key == Code::Escape {
                        0
                    } else if shortcut.key == Code::Enter {
                        1
                    } else if shortcut.key == Code::Digit5 {
                        5
                    } else if shortcut.key == Code::Digit6 {
                        6
                    } else {
                        7
                    };
                    tauri::async_runtime::spawn(async move {
                        let r = if digit == 0 {
                            close_overlay(app.clone()).await
                        } else if digit == 1 {
                            capture_photo(app.clone()).await
                        } else if digit == 5 {
                            capture_fullscreen(app.clone()).await
                        } else {
                            begin_selection(
                                app.clone(),
                                Some(if digit == 6 { "area" } else { "menu" }.into()),
                            )
                            .await
                        };
                        if let Err(e) = r {
                            diagnostics::record(&app, &format!("shortcut action {digit} failed"));
                            error(&app, e);
                        } else {
                            diagnostics::record(
                                &app,
                                &format!("shortcut action {digit} completed"),
                            );
                        }
                    });
                })
                .build(),
        );
    #[cfg(target_os = "macos")]
    let builder = builder.plugin(tauri_nspanel::init());
    builder
        .setup(|app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            #[cfg(target_os = "windows")]
            if let Some(main) = app.get_webview_window("main") {
                main.set_content_protected(true)?;
            }
            let root = app.path().app_data_dir()?;
            let resources = if cfg!(debug_assertions) {
                std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("resources")
            } else {
                app.path().resource_dir()?
            };
            app.manage(Mutex::new(
                backend::Backend::new(root, resources).map_err(std::io::Error::other)?,
            ));
            diagnostics::record(app.handle(), concat!("started ", env!("CARGO_PKG_VERSION")));
            let capture =
                MenuItem::with_id(app, "capture", "Sélection et capture", true, None::<&str>)?;
            let full = MenuItem::with_id(app, "full", "Capture plein écran", true, None::<&str>)?;
            let library = MenuItem::with_id(app, "library", "Bibliothèque", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quitter ArtShot X", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&capture, &full, &library, &quit])?;
            TrayIconBuilder::new()
                .icon(app.default_window_icon().unwrap().clone())
                .tooltip("ArtShot X Preview")
                .menu(&menu)
                .on_menu_event(|app, event| {
                    let a = app.clone();
                    match event.id.as_ref() {
                        "library" => windows::main(app),
                        "quit" => {
                            let active = app
                                .state::<Store>()
                                .lock()
                                .map(|b| b.state.recording.is_some())
                                .unwrap_or(true);
                            if active {
                                windows::show(app, "recording");
                                error(app, "Terminez l’enregistrement avant de quitter".into());
                            } else {
                                app.exit(0);
                            }
                        }
                        id => {
                            let full = id == "full";
                            tauri::async_runtime::spawn(async move {
                                let r = if full {
                                    capture_fullscreen(a.clone()).await
                                } else {
                                    begin_selection(a.clone(), None).await
                                };
                                if let Err(e) = r {
                                    error(&a, e);
                                }
                            });
                        }
                    }
                })
                .build(app)?;
            let modifiers = if cfg!(target_os = "macos") {
                Modifiers::SUPER | Modifiers::ALT | Modifiers::SHIFT
            } else {
                Modifiers::CONTROL | Modifiers::ALT | Modifiers::SHIFT
            };
            for (code, label) in [
                (Code::Digit5, "5"),
                (Code::Digit6, "6"),
                (Code::Digit7, "7"),
            ] {
                if let Err(e) = app
                    .global_shortcut()
                    .register(Shortcut::new(Some(modifiers), code))
                {
                    diagnostics::record(app.handle(), &format!("register {label} failed: {e}"));
                    app.state::<Store>()
                        .lock()
                        .unwrap()
                        .state
                        .shortcut_errors
                        .push(format!("{label} : {e}"));
                } else {
                    diagnostics::record(app.handle(), &format!("register {label} ok"));
                }
            }
            let a = app.handle().clone();
            std::thread::spawn(move || loop {
                std::thread::sleep(std::time::Duration::from_secs(1));
                let result = {
                    let store = a.state::<Store>();
                    let mut b = match store.lock() {
                        Ok(b) => b,
                        Err(_) => break,
                    };
                    if b.state.recording.is_some() {
                        Some(b.check_recording_health())
                    } else {
                        None
                    }
                };
                if let Some(result) = result {
                    if let Err(e) = result {
                        error(&a, e);
                    } else {
                        emit(&a);
                    }
                }
            });
            if std::env::args().any(|arg| arg == "--library") {
                windows::main(app.handle());
            }
            Ok(())
        })
        .on_window_event(|w, event| {
            if w.label() == "main" {
                if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                    api.prevent_close();
                    let _ = w.hide();
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            get_state,
            begin_selection,
            set_selection,
            capture_fullscreen,
            capture_photo,
            start_scroll,
            finish_scroll,
            close_overlay,
            start_recording,
            recording_action,
            update_settings,
            open_editor,
            delete_item,
            save_item,
            copy_image,
            export_image,
            export_video,
            save_image_edits,
            preview_video,
            camera_position,
            open_permissions,
            dismiss_error
        ])
        .run(tauri::generate_context!())
        .expect("ArtShot X failed to start");
}
