use artshot_platform::Display;
#[cfg(target_os = "macos")]
use tauri::LogicalPosition;
#[cfg(not(target_os = "macos"))]
use tauri::PhysicalPosition;
use tauri::{
    AppHandle, LogicalSize, Manager, PhysicalSize, WebviewUrl, WebviewWindow, WebviewWindowBuilder,
};
#[cfg(target_os = "macos")]
use tauri_nspanel::{tauri_panel, ManagerExt, WebviewWindowExt};
#[cfg(target_os = "macos")]
tauri_panel! { panel!(CapturePanel { config: { can_become_key_window:true, can_become_main_window:false, is_floating_panel:true, hides_on_deactivate:false } }) }

/// NSPanel's plugin methods send Objective-C messages directly; unlike Tauri
/// window methods they do not dispatch to AppKit's main thread themselves.
#[cfg(target_os = "macos")]
fn on_main<T: Send + 'static>(
    app: &AppHandle,
    operation: impl FnOnce(&AppHandle) -> Result<T, String> + Send + 'static,
) -> Result<T, String> {
    if objc2_foundation::MainThreadMarker::new().is_some() {
        return operation(app);
    }
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    let main_app = app.clone();
    app.run_on_main_thread(move || {
        let _ = sender.send(operation(&main_app));
    })
    .map_err(|error| error.to_string())?;
    receiver.recv().map_err(|error| error.to_string())?
}

pub fn create(
    app: &AppHandle,
    label: &str,
    width: f64,
    height: f64,
) -> Result<WebviewWindow, String> {
    #[cfg(target_os = "macos")]
    {
        let label = label.to_owned();
        return on_main(app, move |app| create_inner(app, &label, width, height));
    }
    #[cfg(not(target_os = "macos"))]
    create_inner(app, label, width, height)
}
fn create_inner(
    app: &AppHandle,
    label: &str,
    width: f64,
    height: f64,
) -> Result<WebviewWindow, String> {
    if let Some(w) = app.get_webview_window(label) {
        return Ok(w);
    }
    let builder = WebviewWindowBuilder::new(app, label, WebviewUrl::App("index.html".into()))
        .title("ArtShot X")
        .inner_size(width, height)
        .visible(false)
        .focused(false)
        .decorations(false)
        .transparent(true)
        .always_on_top(true)
        .visible_on_all_workspaces(true)
        .skip_taskbar(true)
        .shadow(false)
        .resizable(false)
        .content_protected(true);
    // Keep Tao's internal focusability flags consistent with WS_EX_NOACTIVATE:
    // later visibility/style changes must not accidentally re-enable activation.
    #[cfg(target_os = "windows")]
    let builder = builder.focusable(false);
    let w = builder.build().map_err(|e| e.to_string())?;
    #[cfg(target_os = "macos")]
    {
        use objc2_app_kit::{NSWindowCollectionBehavior, NSWindowStyleMask};
        let p = w.to_panel::<CapturePanel>().map_err(|e| e.to_string())?;
        p.add_style_mask(NSWindowStyleMask::NonactivatingPanel)
            .map_err(|e| e.to_string())?;
        p.set_level(25);
        p.set_hides_on_deactivate(false);
        p.set_opaque(false);
        p.set_collection_behavior(
            NSWindowCollectionBehavior::CanJoinAllSpaces
                | NSWindowCollectionBehavior::FullScreenAuxiliary
                | NSWindowCollectionBehavior::Stationary
                | NSWindowCollectionBehavior::IgnoresCycle,
        );
    }
    #[cfg(target_os = "windows")]
    unsafe {
        use windows::Win32::UI::WindowsAndMessaging::*;
        {
            let hwnd = w.hwnd().map_err(|error| error.to_string())?;
            let h = windows::Win32::Foundation::HWND(hwnd.0);
            let style = GetWindowLongPtrW(h, GWL_EXSTYLE);
            SetWindowLongPtrW(
                h,
                GWL_EXSTYLE,
                style | WS_EX_NOACTIVATE.0 as isize | WS_EX_TOOLWINDOW.0 as isize,
            );
            SetWindowDisplayAffinity(h, WDA_EXCLUDEFROMCAPTURE).map_err(|error| {
                format!("Could not exclude {label} from screen capture: {error}")
            })?;
        }
    }
    Ok(w)
}
pub fn show(app: &AppHandle, label: &str) {
    #[cfg(target_os = "macos")]
    {
        let label = label.to_owned();
        let result = on_main(app, move |app| {
            if let Ok(panel) = app.get_webview_panel(&label) {
                if label == "selection" {
                    // Give the webview a first responder as well as a key panel,
                    // without activating ArtShot or switching the current Space.
                    panel.show_and_make_key();
                } else {
                    panel.show();
                }
                crate::diagnostics::record(
                    app,
                    &format!("show {label} visible={}", panel.is_visible()),
                );
            } else if let Some(window) = app.get_webview_window(&label) {
                window.show().map_err(|error| error.to_string())?;
            }
            Ok(())
        });
        if let Err(error) = result {
            crate::diagnostics::record(app, &format!("show failed: {error}"));
        }
    }
    #[cfg(target_os = "windows")]
    if let Some(window) = app.get_webview_window(label) {
        if let Ok(hwnd) = window.hwnd() {
            unsafe {
                // Tao clears its initial focused(false) marker after creation.
                // Its later show() uses SW_SHOW, which can activate the window.
                let _ = windows::Win32::UI::WindowsAndMessaging::ShowWindow(
                    windows::Win32::Foundation::HWND(hwnd.0),
                    windows::Win32::UI::WindowsAndMessaging::SW_SHOWNOACTIVATE,
                );
            }
        }
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    if let Some(window) = app.get_webview_window(label) {
        let _ = window.show();
    }
}
pub fn hide(app: &AppHandle, label: &str) {
    #[cfg(target_os = "macos")]
    {
        let label = label.to_owned();
        let _ = on_main(app, move |app| {
            if let Ok(panel) = app.get_webview_panel(&label) {
                panel.resign_key_window();
                panel.hide();
                crate::diagnostics::record(
                    app,
                    &format!("hide {label} visible={}", panel.is_visible()),
                );
            } else if let Some(window) = app.get_webview_window(&label) {
                window.hide().map_err(|error| error.to_string())?;
            }
            Ok(())
        });
    }
    #[cfg(target_os = "windows")]
    if let Some(window) = app.get_webview_window(label) {
        if let Ok(hwnd) = window.hwnd() {
            unsafe {
                let _ = windows::Win32::UI::WindowsAndMessaging::ShowWindow(
                    windows::Win32::Foundation::HWND(hwnd.0),
                    windows::Win32::UI::WindowsAndMessaging::SW_HIDE,
                );
            }
        }
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    if let Some(window) = app.get_webview_window(label) {
        let _ = window.hide();
    }
}
pub fn hide_overlays(app: &AppHandle) {
    for label in ["selection", "quick", "scrolling", "camera"] {
        hide(app, label);
    }
}
pub fn selection(app: &AppHandle, d: &Display) -> Result<(), String> {
    let w = create(
        app,
        "selection",
        d.width as f64 / d.scale_factor as f64,
        d.height as f64 / d.scale_factor as f64,
    )?;
    w.set_size(PhysicalSize::new(d.width, d.height))
        .map_err(|e| e.to_string())?;
    #[cfg(target_os = "macos")]
    w.set_position(LogicalPosition::new(
        d.x as f64 / d.scale_factor as f64,
        d.y as f64 / d.scale_factor as f64,
    ))
    .map_err(|e| e.to_string())?;
    #[cfg(not(target_os = "macos"))]
    w.set_position(PhysicalPosition::new(d.x, d.y))
        .map_err(|e| e.to_string())?;
    show(app, "selection");
    if !w.is_visible().map_err(|e| e.to_string())? {
        return Err("La fenêtre de sélection n’a pas pu être affichée".into());
    }
    Ok(())
}
pub fn floating(
    app: &AppHandle,
    label: &str,
    d: &Display,
    width: f64,
    height: f64,
) -> Result<(), String> {
    let w = create(app, label, width, height)?;
    w.set_size(LogicalSize::new(width, height))
        .map_err(|e| e.to_string())?;
    #[cfg(target_os = "macos")]
    w.set_position(LogicalPosition::new(
        d.x as f64 / d.scale_factor as f64 + 20.,
        d.y as f64 / d.scale_factor as f64 + d.height as f64 / d.scale_factor as f64 - height - 30.,
    ))
    .map_err(|e| e.to_string())?;
    #[cfg(not(target_os = "macos"))]
    w.set_position(PhysicalPosition::new(
        d.x + 20,
        d.y + d.height as i32 - ((height + 30.) * d.scale_factor as f64) as i32,
    ))
    .map_err(|e| e.to_string())?;
    show(app, label);
    if !w.is_visible().map_err(|e| e.to_string())? {
        return Err(format!("La fenêtre {label} n’a pas pu être affichée"));
    }
    Ok(())
}
pub fn main(app: &AppHandle) {
    #[cfg(target_os = "macos")]
    {
        let _ = on_main(app, |app| {
            if let Some(window) = app.get_webview_window("main") {
                window.show().map_err(|error| error.to_string())?;
                window.set_focus().map_err(|error| error.to_string())?;
            }
            Ok(())
        });
    }
    #[cfg(not(target_os = "macos"))]
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.set_focus();
    }
}
