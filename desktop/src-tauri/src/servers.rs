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

/// Deepest mount path discovery supports, in path segments — a proxy mount is
/// one or two deep in practice. Bounds the probing when the address is a link
/// pasted from inside the app; a base typed exactly is probed at any depth.
pub const MAX_MOUNT_DEPTH: usize = 3;

fn split_base(input: &str) -> Result<(String, String), ServerError> {
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
    Ok((origin, parsed.path().trim_end_matches('/').to_string()))
}

/// Canonical form of a server address: origin plus the path it is served under.
/// The path is kept, so a Sure mounted under a prefix (`https://host/sure`)
/// works; `base_candidates` is what still resolves a pasted deep link.
pub fn normalize_server_url(input: &str) -> Result<String, ServerError> {
    let (origin, path) = split_base(input)?;
    Ok(format!("{origin}{path}"))
}

/// Bases to try for a normalized URL, most specific first and always ending at
/// the origin. A prefix-mounted server and a pasted deep link are the same
/// shape, so the server decides: the first candidate whose `/up` answers wins.
///
/// The address as typed comes first, so a base entered exactly is probed however
/// deep it is. The rest are every mount depth up to `MAX_MOUNT_DEPTH`, which is
/// what makes the walk finite for a link pasted from inside the app.
pub fn base_candidates(normalized: &str) -> Vec<String> {
    let Ok((origin, path)) = split_base(normalized) else {
        return vec![normalized.to_string()];
    };
    let segments: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    let base_at = |depth: usize| {
        format!("{origin}{}", segments[..depth].iter().map(|s| format!("/{s}")).collect::<String>())
    };
    let mut candidates = vec![base_at(segments.len())];
    candidates.extend(
        (0..=segments.len().min(MAX_MOUNT_DEPTH))
            .rev()
            .filter(|&depth| depth != segments.len()) // already first
            .map(base_at),
    );
    candidates
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
    // Atomic write: write a temp file in the same dir then rename over the
    // destination, so an interrupted write can't leave truncated/invalid JSON.
    let tmp = dir.join(format!(".{name}.tmp"));
    std::fs::write(&tmp, contents).map_err(|e| ServerError::Keyring(e.to_string()))?;
    std::fs::rename(&tmp, dir.join(name)).map_err(|e| ServerError::Keyring(e.to_string()))
}

pub struct ServerStore;

impl ServerStore {
    pub fn load() -> Vec<ServerEntry> {
        // The on-disk file is the durable source (Keychain is best-effort and
        // may not persist on unsigned builds), so read it first and fall back to
        // Keychain only when the file is missing/invalid.
        if let Some(list) =
            file_read("servers.json").and_then(|j| serde_json::from_str::<Vec<ServerEntry>>(&j).ok())
        {
            return list;
        }
        if let Ok(entry) = keyring_entry() {
            if let Ok(json) = entry.get_password() {
                if let Ok(list) = serde_json::from_str::<Vec<ServerEntry>>(&json) {
                    return list;
                }
            }
        }
        Vec::new()
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
    if let Some(url) = file_read("active_server").filter(|s| !s.is_empty()) {
        return Some(url);
    }
    if let Ok(entry) = keyring::Entry::new(KEYRING_SERVICE, KEYRING_ACTIVE) {
        if let Ok(url) = entry.get_password() {
            if !url.is_empty() {
                return Some(url);
            }
        }
    }
    None
}

pub fn save_active(url: &str) -> Result<(), ServerError> {
    if let Ok(entry) = keyring::Entry::new(KEYRING_SERVICE, KEYRING_ACTIVE) {
        let _ = entry.set_password(url);
    }
    file_write("active_server", url)
}

/// True if `url` is `base` itself or sits under it. The boundary check is what
/// keeps `https://sure.example.com.evil.test` from passing as `https://sure.example.com`.
pub fn base_covers(base: &str, url: &str) -> bool {
    url == base || url.strip_prefix(base).is_some_and(|rest| rest.starts_with('/'))
}

/// True if `url` is served by a server the user has saved (or the active one).
/// Gates deep-link navigation and SSO so only trusted origins can drive them.
pub fn is_known_server(url: &str) -> bool {
    let Ok(canonical) = normalize_server_url(url) else {
        return false;
    };
    ServerStore::load().iter().any(|e| base_covers(&e.url, &canonical))
        || load_active().is_some_and(|active| base_covers(&active, &canonical))
}
