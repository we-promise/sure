use tauri::menu::{AboutMetadata, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::Manager;

pub fn build(app: &tauri::AppHandle) -> tauri::Result<Menu<tauri::Wry>> {
    let pkg = app.package_info().clone();

    let prefs = MenuItem::with_id(app, "preferences", "Preferences…", true, Some("Cmd+,"))?;
    let switch = MenuItem::with_id(app, "switch_server", "Switch Server…", true, Some("Cmd+Shift+O"))?;
    let app_menu = Submenu::with_items(
        app,
        &pkg.name,
        true,
        &[
            &PredefinedMenuItem::about(app, Some(&pkg.name), Some(AboutMetadata::default()))?,
            &PredefinedMenuItem::separator(app)?,
            &prefs,
            &switch,
            &PredefinedMenuItem::separator(app)?,
            &PredefinedMenuItem::hide(app, None)?,
            &PredefinedMenuItem::hide_others(app, None)?,
            &PredefinedMenuItem::separator(app)?,
            &PredefinedMenuItem::quit(app, None)?,
        ],
    )?;

    let file_menu = Submenu::with_items(
        app,
        "File",
        true,
        &[&PredefinedMenuItem::close_window(app, None)?],
    )?;

    let edit_menu = Submenu::with_items(
        app,
        "Edit",
        true,
        &[
            &PredefinedMenuItem::undo(app, None)?,
            &PredefinedMenuItem::redo(app, None)?,
            &PredefinedMenuItem::separator(app)?,
            &PredefinedMenuItem::cut(app, None)?,
            &PredefinedMenuItem::copy(app, None)?,
            &PredefinedMenuItem::paste(app, None)?,
            &PredefinedMenuItem::select_all(app, None)?,
        ],
    )?;

    let reload = MenuItem::with_id(app, "reload", "Reload", true, Some("Cmd+R"))?;
    let view_menu = Submenu::with_items(app, "View", true, &[&reload])?;

    let window_menu = Submenu::with_items(
        app,
        "Window",
        true,
        &[
            &PredefinedMenuItem::minimize(app, None)?,
            &PredefinedMenuItem::maximize(app, None)?,
        ],
    )?;

    Menu::with_items(app, &[&app_menu, &file_menu, &edit_menu, &view_menu, &window_menu])
}

pub fn on_event(app: &tauri::AppHandle, id: &str) {
    match id {
        // Handled entirely in Rust: showing the prefs window does not depend on
        // the remote page's IPC being available, so it works on any page.
        "preferences" | "switch_server" => {
            if let Some(w) = app.get_webview_window("prefs") {
                let _ = w.show();
                let _ = w.set_focus();
            }
        }
        "reload" => {
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.eval("window.location.reload()");
            }
        }
        _ => {}
    }
}
