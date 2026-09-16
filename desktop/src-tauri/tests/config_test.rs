use serde_json::Value;

#[test]
fn local_webview_csp_is_enabled_and_restrictive() {
    let config: Value = serde_json::from_str(include_str!("../tauri.conf.json")).unwrap();
    let csp = config["app"]["security"]["csp"].as_str().expect("CSP must be a string");

    for directive in [
        "default-src 'self'",
        "base-uri 'self'",
        "object-src 'none'",
        "script-src 'self'",
        "style-src 'self' 'unsafe-inline'",
        "connect-src 'self' ipc: http://ipc.localhost",
    ] {
        assert!(csp.contains(directive), "CSP is missing {directive:?}");
    }
    assert!(!csp.contains("connect-src *"));
}
