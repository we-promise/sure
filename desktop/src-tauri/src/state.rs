use std::sync::Mutex;

/// A desktop-SSO flow in progress: the PKCE verifier and the server it targets,
/// held until the sure://sso/callback deep link arrives.
pub struct PendingSso {
    pub verifier: String,
    pub server: String,
}

#[derive(Default)]
pub struct AppState {
    pub active_server: Mutex<Option<String>>,
    pub pending_sso: Mutex<Option<PendingSso>>,
}
