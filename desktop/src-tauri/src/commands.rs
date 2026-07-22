use crate::servers::{
    health_check_url, is_healthy_status, normalize_server_url, ServerEntry, ServerStore,
};
use crate::state::AppState;
use tauri::{Emitter, State};
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
    *state.active_server.lock().unwrap() = Some(url.clone());
    let _ = app.emit("active-server-changed", url);
}

/// Begin SSO in the system browser (so passkeys/WebAuthn work). Generates a
/// PKCE pair, stashes the verifier + server for the sure://sso/callback handoff,
/// and opens {server}/auth/desktop/{provider}?code_challenge=... in the browser.
#[tauri::command]
pub fn start_sso(server: String, provider: String, state: State<AppState>) -> Result<(), String> {
    let canonical = normalize_server_url(&server).map_err(|e| e.to_string())?;
    // Providers are simple identifiers ([a-z0-9_]); reject anything else so it
    // can't smuggle extra path/query into the opened URL.
    if provider.is_empty() || !provider.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') {
        return Err("invalid provider".into());
    }

    let pkce = crate::sso::generate_pkce();
    let url = format!("{}/auth/desktop/{}?code_challenge={}", canonical, provider, pkce.challenge);

    *state.pending_sso.lock().unwrap() = Some(crate::state::PendingSso {
        verifier: pkce.verifier,
        server: canonical,
    });

    open::that(url).map_err(|e| e.to_string())
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
