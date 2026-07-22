use std::sync::Mutex;

#[derive(Default)]
pub struct AppState {
    pub active_server: Mutex<Option<String>>,
}
