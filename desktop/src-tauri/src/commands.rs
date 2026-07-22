use crate::servers::{
    health_check_url, is_healthy_status, normalize_server_url, ServerEntry, ServerStore,
};
use crate::state::AppState;
use tauri::{Emitter, State};

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
    state.active_server.lock().unwrap().clone()
}

#[tauri::command]
pub fn set_active_server(url: String, state: State<AppState>, app: tauri::AppHandle) {
    *state.active_server.lock().unwrap() = Some(url.clone());
    let _ = app.emit("active-server-changed", url);
}
