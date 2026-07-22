use tauri::menu::{
    AboutMetadata, Menu, MenuItem, PredefinedMenuItem, Submenu,
};
use tauri::{Emitter, Manager};

pub fn build(app: &tauri::AppHandle) -> tauri::Result<Menu<tauri::Wry>> {
    let pkg = app.package_info().clone();

    let prefs = MenuItem::with_id(app, "preferences", "Preferences…", true, Some("Cmd+,"))?;
    let app_menu = Submenu::with_items(
        app,
        &pkg.name,
        true,
        &[
            &PredefinedMenuItem::about(app, Some(&pkg.name), Some(AboutMetadata::default()))?,
            &PredefinedMenuItem::separator(app)?,
            &prefs,
            &PredefinedMenuItem::separator(app)?,
            &PredefinedMenuItem::hide(app, None)?,
            &PredefinedMenuItem::hide_others(app, None)?,
            &PredefinedMenuItem::separator(app)?,
            &PredefinedMenuItem::quit(app, None)?,
        ],
    )?;

    let new_window = MenuItem::with_id(app, "new_window", "New Window", true, Some("Cmd+N"))?;
    let file_menu = Submenu::with_items(
        app,
        "File",
        true,
        &[&new_window, &PredefinedMenuItem::close_window(app, None)?],
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

    let switch = MenuItem::with_id(app, "switch_server", "Switch Server…", true, Some("Cmd+Shift+O"))?;
    let window_menu = Submenu::with_items(
        app,
        "Window",
        true,
        &[
            &PredefinedMenuItem::minimize(app, None)?,
            &PredefinedMenuItem::maximize(app, None)?,
            &PredefinedMenuItem::separator(app)?,
            &switch,
        ],
    )?;

    Menu::with_items(app, &[&app_menu, &file_menu, &edit_menu, &view_menu, &window_menu])
}

pub fn on_event(app: &tauri::AppHandle, id: &str) {
    match id {
        "preferences" => { let _ = app.emit("menu://preferences", ()); }
        "switch_server" => { let _ = app.emit("menu://switch-server", ()); }
        "reload" => {
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.eval("window.location.reload()");
            }
        }
        "new_window" => { let _ = app.emit("menu://new-window", ()); }
        _ => {}
    }
}
