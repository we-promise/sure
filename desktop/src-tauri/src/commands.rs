use crate::servers::{
    health_check_url, is_healthy_status, normalize_server_url, ServerEntry, ServerStore,
};
use crate::state::AppState;
use tauri::{Emitter, Manager, State};
use tauri_plugin_autostart::ManagerExt;

#[tauri::command]
pub fn list_servers() -> Vec<ServerEntry> {
    ServerStore::load()
}

#[tauri::command]
pub fn add_server(url: String, label: String) -> Result<Vec<ServerEntry>, String> {
    let canonical = normalize_server_url(&url).map_err(|e| e.to_string())?;
    let label = if label.trim().is_empty() { canonical.clone() } else { label };
    ServerStore::add(ServerEntry { url: canonical, label }).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn remove_server(url: String) -> Result<Vec<ServerEntry>, String> {
    ServerStore::remove(&url).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn check_server(url: String) -> Result<bool, String> {
    let canonical = normalize_server_url(&url).map_err(|e| e.to_string())?;
    let health = health_check_url(&canonical);
    match ureq::get(&health).timeout(std::time::Duration::from_secs(6)).call() {
        Ok(resp) => Ok(is_healthy_status(resp.status())),
        Err(ureq::Error::Status(code, _)) => Ok(is_healthy_status(code)),
        Err(e) => Err(e.to_string()),
    }
}

#[tauri::command]
pub fn active_server(state: State<AppState>) -> Option<String> {
    if let Some(url) = state.active_server.lock().unwrap().clone() {
        return Some(url);
    }
    // Fall back to the persisted value so a relaunch resumes the last server.
    crate::servers::load_active()
}

#[tauri::command]
pub fn set_active_server(url: String, state: State<AppState>, app: tauri::AppHandle) {
    let _ = crate::servers::save_active(&url);
    // Grant this origin the runtime IPC capability before we navigate to it, so
    // the injected bridge works — instead of a static wildcard that would grant
    // IPC to any origin.
    grant_server_capability(&app, &url);
    *state.active_server.lock().unwrap() = Some(url.clone());
    let _ = app.emit("active-server-changed", url);
}

/// Grant the main webview IPC access for exactly one server origin, added at
/// runtime so we never whitelist arbitrary (`https://*`) origins. Idempotent per
/// origin. Mirrors the minimal permission set the bridge needs.
pub fn grant_server_capability(app: &tauri::AppHandle, origin: &str) {
    let Ok(canonical) = normalize_server_url(origin) else {
        return;
    };
    {
        let state = app.state::<AppState>();
        let mut granted = state.granted_origins.lock().unwrap();
        if !granted.insert(canonical.clone()) {
            return; // already granted this origin
        }
    }
    let id: String = format!(
        "remote-{}",
        canonical
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
            .collect::<String>()
    );
    let capability = tauri::ipc::CapabilityBuilder::new(id)
        .window("main")
        .remote(format!("{canonical}/**"))
        .permission("core:window:allow-start-dragging")
        .permission("core:window:allow-show")
        .permission("core:window:allow-set-focus")
        .permission("core:event:allow-emit")
        .permission("core:event:allow-listen")
        .permission("notification:default");
    if let Err(e) = app.add_capability(capability) {
        eprintln!("[sure] failed to grant capability for {canonical}: {e}");
    }
}

/// Begin SSO in the system browser (so passkeys/WebAuthn work). Generates a
/// PKCE pair, stashes the verifier + server for the sure://sso/callback handoff,
/// and opens {server}/auth/desktop/{provider}?code_challenge=... in the browser.
///
/// Callable directly (local pages) or via the "sure://start-sso" event (the
/// remote Sure page can emit events but cannot invoke custom commands).
pub fn begin_sso(app: &tauri::AppHandle, server: String, provider: String) -> Result<(), String> {
    let canonical = normalize_server_url(&server).map_err(|e| e.to_string())?;
    // Only start SSO for a server the user has actually added. This event can be
    // emitted by any page loaded in the webview, so gate it to trusted origins
    // to prevent a rogue page from opening the browser to an attacker URL.
    if !crate::servers::is_known_server(&canonical) {
        return Err("unknown server".into());
    }
    // Providers are simple identifiers ([a-z0-9_-]); reject anything else so it
    // can't smuggle extra path/query into the opened URL.
    if provider.is_empty() || !provider.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') {
        return Err("invalid provider".into());
    }

    let pkce = crate::sso::generate_pkce();
    let url = format!("{}/auth/desktop/{}?code_challenge={}", canonical, provider, pkce.challenge);

    *app.state::<AppState>().pending_sso.lock().unwrap() = Some(crate::state::PendingSso {
        verifier: pkce.verifier,
        server: canonical,
    });

    open::that(url).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn start_sso(server: String, provider: String, app: tauri::AppHandle) -> Result<(), String> {
    begin_sso(&app, server, provider)
}

#[tauri::command]
pub fn get_launch_at_login(app: tauri::AppHandle) -> bool {
    app.autolaunch().is_enabled().unwrap_or(false)
}

#[tauri::command]
pub fn set_launch_at_login(app: tauri::AppHandle, enabled: bool) -> Result<(), String> {
    let mgr = app.autolaunch();
    let res = if enabled { mgr.enable() } else { mgr.disable() };
    res.map_err(|e| e.to_string())
}
