use serde::{Deserialize, Serialize};
use url::Url;

const KEYRING_SERVICE: &str = "app.sure.desktop";
const KEYRING_ACCOUNT: &str = "servers";
const KEYRING_ACTIVE: &str = "active_server";

#[derive(Debug)]
pub enum ServerError {
    InvalidUrl(String),
    Keyring(String),
}

impl std::fmt::Display for ServerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ServerError::InvalidUrl(m) => write!(f, "Invalid server URL: {m}"),
            ServerError::Keyring(m) => write!(f, "Keychain error: {m}"),
        }
    }
}

impl Serialize for ServerError {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.to_string())
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ServerEntry {
    pub url: String,
    pub label: String,
}

pub fn normalize_server_url(input: &str) -> Result<String, ServerError> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Err(ServerError::InvalidUrl("empty".into()));
    }
    let with_scheme = if trimmed.contains("://") {
        trimmed.to_string()
    } else {
        format!("https://{trimmed}")
    };
    let parsed = Url::parse(&with_scheme).map_err(|e| ServerError::InvalidUrl(e.to_string()))?;
    let host = parsed.host_str().ok_or_else(|| ServerError::InvalidUrl("missing host".into()))?;
    let scheme = parsed.scheme();
    if scheme != "http" && scheme != "https" {
        return Err(ServerError::InvalidUrl(format!("unsupported scheme {scheme}")));
    }
    let origin = match parsed.port() {
        Some(p) => format!("{scheme}://{host}:{p}"),
        None => format!("{scheme}://{host}"),
    };
    Ok(origin)
}

pub fn health_check_url(base: &str) -> String {
    format!("{}/up", base.trim_end_matches('/'))
}

pub fn is_healthy_status(status: u16) -> bool {
    status == 200
}

fn keyring_entry() -> Result<keyring::Entry, ServerError> {
    keyring::Entry::new(KEYRING_SERVICE, KEYRING_ACCOUNT)
        .map_err(|e| ServerError::Keyring(e.to_string()))
}

pub struct ServerStore;

impl ServerStore {
    pub fn load() -> Vec<ServerEntry> {
        let Ok(entry) = keyring_entry() else { return vec![] };
        match entry.get_password() {
            Ok(json) => serde_json::from_str(&json).unwrap_or_default(),
            Err(_) => vec![],
        }
    }

    pub fn save(entries: &[ServerEntry]) -> Result<(), ServerError> {
        let json = serde_json::to_string(entries).map_err(|e| ServerError::Keyring(e.to_string()))?;
        keyring_entry()?
            .set_password(&json)
            .map_err(|e| ServerError::Keyring(e.to_string()))
    }

    pub fn add(entry: ServerEntry) -> Result<Vec<ServerEntry>, ServerError> {
        let mut list = Self::load();
        list.retain(|e| e.url != entry.url);
        list.insert(0, entry);
        Self::save(&list)?;
        Ok(list)
    }

    pub fn remove(url: &str) -> Result<Vec<ServerEntry>, ServerError> {
        let mut list = Self::load();
        list.retain(|e| e.url != url);
        Self::save(&list)?;
        Ok(list)
    }
}

/// The last server the user connected to, persisted so the app can resume
/// straight to it on the next launch instead of showing the picker again.
pub fn load_active() -> Option<String> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, KEYRING_ACTIVE).ok()?;
    entry.get_password().ok()
}

pub fn save_active(url: &str) -> Result<(), ServerError> {
    keyring::Entry::new(KEYRING_SERVICE, KEYRING_ACTIVE)
        .and_then(|e| e.set_password(url))
        .map_err(|e| ServerError::Keyring(e.to_string()))
}
