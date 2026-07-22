use tauri::Manager;
use tauri_plugin_decorum::WebviewWindowExt;
use window_vibrancy::{apply_vibrancy, NSVisualEffectMaterial, NSVisualEffectState};

pub fn setup(app: &tauri::App) -> Result<(), Box<dyn std::error::Error>> {
    let window = app.get_webview_window("main").expect("main window exists");

    // Vibrancy that follows system light/dark automatically.
    apply_vibrancy(
        &window,
        NSVisualEffectMaterial::Sidebar,
        Some(NSVisualEffectState::FollowsWindowActiveState),
        None,
    )
    .expect("vibrancy is macOS-only");

    // Overlay titlebar + inset traffic lights so content sits under a clean bar.
    window.create_overlay_titlebar()?;
    window.set_traffic_lights_inset(16.0, 20.0)?;

    Ok(())
}
