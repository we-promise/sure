use url::Url;

pub struct DeepLinkTarget {
    pub server: String,
    pub path: String,
}

/// The result of an SSO handoff deep link: `sure://sso/callback?code=...` returns
/// `Ok(code)`, `sure://sso/callback?error=...` returns `Err(error)`.
pub enum SsoCallback {
    Code(String),
    Error(String),
}

/// Parse a `sure://sso/callback` deep link, or None if it is not one.
pub fn parse_sso_callback(url: &str) -> Option<SsoCallback> {
    let parsed = Url::parse(url).ok()?;
    if parsed.scheme() != "sure" || parsed.host_str() != Some("sso") || parsed.path() != "/callback" {
        return None;
    }
    let mut code = None;
    let mut error = None;
    for (k, v) in parsed.query_pairs() {
        match k.as_ref() {
            "code" => code = Some(v.into_owned()),
            "error" => error = Some(v.into_owned()),
            _ => {}
        }
    }
    match (code, error) {
        (Some(c), _) => Some(SsoCallback::Code(c)),
        (None, Some(e)) => Some(SsoCallback::Error(e)),
        _ => None,
    }
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
