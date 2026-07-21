use sure_desktop_lib::servers::{normalize_server_url, health_check_url, is_healthy_status};

#[test]
fn normalizes_bare_host_to_https_origin() {
    assert_eq!(normalize_server_url("app.example.com").unwrap(), "https://app.example.com");
}

#[test]
fn preserves_explicit_http_scheme_and_port() {
    assert_eq!(normalize_server_url("http://localhost:3000/").unwrap(), "http://localhost:3000");
}

#[test]
fn strips_path_and_trailing_slash() {
    assert_eq!(normalize_server_url("https://s.example.com/session/new").unwrap(), "https://s.example.com");
}

#[test]
fn rejects_empty_input() {
    assert!(normalize_server_url("   ").is_err());
}

#[test]
fn builds_health_url() {
    assert_eq!(health_check_url("https://s.example.com"), "https://s.example.com/up");
}

#[test]
fn only_200_is_healthy() {
    assert!(is_healthy_status(200));
    assert!(!is_healthy_status(302));
    assert!(!is_healthy_status(500));
}
