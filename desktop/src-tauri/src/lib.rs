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
                // Hide the prefs window on close instead of destroying it, so
                // reopening it from the menu keeps working (a destroyed webview
                // makes get_webview_window("prefs") return None).
                use tauri::Manager;
                if let Some(prefs) = app.get_webview_window("prefs") {
                    let prefs_for_event = prefs.clone();
                    prefs.on_window_event(move |event| {
                        if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                            api.prevent_close();
                            let _ = prefs_for_event.hide();
                        }
                    });
                }
            }
            {
                // The remote Sure page can emit events but cannot invoke custom
                // commands, so SSO is triggered via an event instead of invoke.
                use tauri::Listener;
                let handle = app.handle().clone();
                app.listen_any("sure://start-sso", move |event| {
                    #[derive(serde::Deserialize)]
                    struct StartSso {
                        server: String,
                        provider: String,
                    }
                    if let Ok(p) = serde_json::from_str::<StartSso>(event.payload()) {
                        if let Err(e) = commands::begin_sso(&handle, p.server, p.provider) {
                            eprintln!("[sure] start-sso failed: {e}");
                        }
                    }
                });
            }
            {
                use tauri::Manager;
                use tauri_plugin_deep_link::DeepLinkExt;
                let handle = app.handle().clone();
                app.deep_link().on_open_url(move |event| {
                    for url in event.urls() {
                        let u = url.as_str();
                        // SSO handoff first: exchange the one-time code (bound to
                        // our stored PKCE verifier) for a session in the webview.
                        // POST it via a form so the verifier never appears in a
                        // URL / server log (RFC 7636 keeps the verifier secret).
                        if let Some(cb) = deep_link::parse_sso_callback(u) {
                            let pending = handle.state::<AppState>().pending_sso.lock().unwrap().take();
                            if let (deep_link::SsoCallback::Code(code), Some(p)) = (cb, pending) {
                                if let Some(w) = handle.get_webview_window("main") {
                                    let action = format!("{}/sessions/desktop_exchange", p.server);
                                    let js = format!(
                                        "(function(){{var f=document.createElement('form');f.method='POST';f.action={};\
                                         var c=document.createElement('input');c.type='hidden';c.name='code';c.value={};f.appendChild(c);\
                                         var v=document.createElement('input');v.type='hidden';v.name='code_verifier';v.value={};f.appendChild(v);\
                                         document.body.appendChild(f);f.submit();}})();",
                                        serde_json::to_string(&action).unwrap_or_default(),
                                        serde_json::to_string(&code).unwrap_or_default(),
                                        serde_json::to_string(&p.verifier).unwrap_or_default(),
                                    );
                                    let _ = w.eval(&js);
                                }
                            }
                            continue;
                        }
                        // Generic sure://{host}/{path} navigation — only to a
                        // server the user has saved, so a malicious deep link
                        // can't load an arbitrary origin into the main webview.
                        if let Some(target) = deep_link::parse(u) {
                            if servers::is_known_server(&target.server) {
                                if let Some(w) = handle.get_webview_window("main") {
                                    let dest = format!("{}{}", target.server, target.path);
                                    let _ = w.eval(&format!("window.location.assign({:?})", dest));
                                }
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
