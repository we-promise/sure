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

// On-disk fallback: Keychain items are unreliable for unsigned/dev builds
// (they don't persist across launches without proper code signing), so we also
// mirror the data to the app support directory. Server URLs are not secrets.
fn data_dir() -> Option<std::path::PathBuf> {
    let home = std::env::var_os("HOME")?;
    let dir = std::path::Path::new(&home)
        .join("Library/Application Support")
        .join(KEYRING_SERVICE);
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir)
}

fn file_read(name: &str) -> Option<String> {
    std::fs::read_to_string(data_dir()?.join(name)).ok()
}

fn file_write(name: &str, contents: &str) -> Result<(), ServerError> {
    let dir = data_dir().ok_or_else(|| ServerError::Keyring("no data dir".into()))?;
    std::fs::write(dir.join(name), contents).map_err(|e| ServerError::Keyring(e.to_string()))
}

pub struct ServerStore;

impl ServerStore {
    pub fn load() -> Vec<ServerEntry> {
        // Keychain first (signed builds), then the on-disk fallback.
        if let Ok(entry) = keyring_entry() {
            if let Ok(json) = entry.get_password() {
                if let Ok(list) = serde_json::from_str::<Vec<ServerEntry>>(&json) {
                    return list;
                }
            }
        }
        file_read("servers.json")
            .and_then(|j| serde_json::from_str::<Vec<ServerEntry>>(&j).ok())
            .unwrap_or_default()
    }

    pub fn save(entries: &[ServerEntry]) -> Result<(), ServerError> {
        let json = serde_json::to_string(entries).map_err(|e| ServerError::Keyring(e.to_string()))?;
        // Best-effort Keychain; authoritative on-disk write.
        if let Ok(entry) = keyring_entry() {
            let _ = entry.set_password(&json);
        }
        file_write("servers.json", &json)
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
    if let Ok(entry) = keyring::Entry::new(KEYRING_SERVICE, KEYRING_ACTIVE) {
        if let Ok(url) = entry.get_password() {
            if !url.is_empty() {
                return Some(url);
            }
        }
    }
    file_read("active_server").filter(|s| !s.is_empty())
}

pub fn save_active(url: &str) -> Result<(), ServerError> {
    if let Ok(entry) = keyring::Entry::new(KEYRING_SERVICE, KEYRING_ACTIVE) {
        let _ = entry.set_password(url);
    }
    file_write("active_server", url)
}
