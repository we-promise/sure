pub mod badge;
pub mod commands;
pub mod deep_link;
pub mod menu;
pub mod notifications;
pub mod servers;
pub mod sso;
pub mod state;
pub mod window;

use state::AppState;

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_decorum::init())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .plugin(tauri_plugin_deep_link::init())
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![
            commands::list_servers,
            commands::add_server,
            commands::remove_server,
            commands::check_server,
            commands::active_server,
            commands::set_active_server,
            commands::get_launch_at_login,
            commands::set_launch_at_login,
            commands::start_sso,
        ])
        .setup(|app| {
            window::setup(app)?;
            let menu = menu::build(app.handle())?;
            app.set_menu(menu)?;
            app.on_menu_event(|app, event| menu::on_event(app, event.id().as_ref()));
            notifications::register(app.handle());
            badge::register(app.handle());
            {
                use tauri::Manager;
                use tauri_plugin_deep_link::DeepLinkExt;
                let handle = app.handle().clone();
                app.deep_link().on_open_url(move |event| {
                    for url in event.urls() {
                        let u = url.as_str();
                        // SSO handoff first: exchange the one-time code (bound to
                        // our stored PKCE verifier) for a session in the webview.
                        if let Some(cb) = deep_link::parse_sso_callback(u) {
                            let pending = handle.state::<AppState>().pending_sso.lock().unwrap().take();
                            if let (deep_link::SsoCallback::Code(code), Some(p)) = (cb, pending) {
                                if let Some(w) = handle.get_webview_window("main") {
                                    let dest = format!(
                                        "{}/sessions/desktop_exchange?code={}&code_verifier={}",
                                        p.server, code, p.verifier
                                    );
                                    let _ = w.eval(&format!("window.location.assign({:?})", dest));
                                }
                            }
                            continue;
                        }
                        if let Some(target) = deep_link::parse(u) {
                            if let Some(w) = handle.get_webview_window("main") {
                                let dest = format!("{}{}", target.server, target.path);
                                let _ = w.eval(&format!("window.location.assign({:?})", dest));
                            }
                        }
                    }
                });
            }
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
