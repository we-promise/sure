pub mod badge;
pub mod commands;
pub mod menu;
pub mod notifications;
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
            let menu = menu::build(app.handle())?;
            app.set_menu(menu)?;
            app.on_menu_event(|app, event| menu::on_event(app, event.id().as_ref()));
            notifications::register(app.handle());
            badge::register(app.handle());
            Ok(())
        })
        .on_page_load(|window, payload| {
            if payload.event() == tauri::webview::PageLoadEvent::Finished {
                const BRIDGE: &str = include_str!("../../dist/bridge.js");
                let _ = window.eval(BRIDGE);
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running Sure Desktop");
}
