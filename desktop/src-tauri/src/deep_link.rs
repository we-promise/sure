use url::Url;

pub struct DeepLinkTarget {
    pub server: String,
    pub path: String,
}

pub fn parse(url: &str) -> Option<DeepLinkTarget> {
    if !url.starts_with("sure://") {
        return None;
    }
    let parsed = Url::parse(url).ok()?;
    if parsed.scheme() != "sure" {
        return None;
    }
    let host = parsed.host_str()?;
    let server = match parsed.port() {
        Some(p) => format!("https://{host}:{p}"),
        None => format!("https://{host}"),
    };
    let path = if parsed.path().is_empty() { "/".to_string() } else { parsed.path().to_string() };
    Some(DeepLinkTarget { server, path })
}
