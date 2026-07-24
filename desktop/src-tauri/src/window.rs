use tauri::Manager;
use tauri_plugin_decorum::WebviewWindowExt;

pub fn setup(app: &tauri::App) -> Result<(), Box<dyn std::error::Error>> {
    let window = app.get_webview_window("main").expect("main window exists");

    // The window is opaque (the app paints its own solid backgrounds), so we
    // skip the transparent-window vibrancy blur — it never showed through and
    // forced the compositor to re-blend the webview every frame (high GPU).

    // Overlay titlebar + inset traffic lights so content sits under a clean bar.
    window.create_overlay_titlebar()?;
    window.set_traffic_lights_inset(16.0, 20.0)?;

    Ok(())
}
