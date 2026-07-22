pub mod commands;
pub mod servers;
pub mod state;
pub mod window;

use state::AppState;

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_decorum::init())
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![
            commands::list_servers,
            commands::add_server,
            commands::remove_server,
            commands::check_server,
            commands::active_server,
            commands::set_active_server,
        ])
        .setup(|app| {
            window::setup(app)?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Sure Desktop");
}
