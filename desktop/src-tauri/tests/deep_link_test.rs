use sure_desktop_lib::deep_link::{parse, parse_sso_callback, SsoCallback};

#[test]
fn parses_server_and_path() {
    let t = parse("sure://app.example.com/accounts/123").unwrap();
    assert_eq!(t.server, "https://app.example.com");
    assert_eq!(t.path, "/accounts/123");
}

#[test]
fn parses_with_port_and_defaults_root_path() {
    let t = parse("sure://localhost:3000").unwrap();
    assert_eq!(t.server, "https://localhost:3000");
    assert_eq!(t.path, "/");
}

#[test]
fn rejects_other_schemes() {
    assert!(parse("https://app.example.com/x").is_none());
    assert!(parse("sureapp://oauth/callback").is_none());
}

#[test]
fn parses_sso_callback_code() {
    match parse_sso_callback("sure://sso/callback?code=abc123") {
        Some(SsoCallback::Code(c)) => assert_eq!(c, "abc123"),
        _ => panic!("expected code"),
    }
}

#[test]
fn parses_sso_callback_error() {
    match parse_sso_callback("sure://sso/callback?error=account_not_linked") {
        Some(SsoCallback::Error(e)) => assert_eq!(e, "account_not_linked"),
        _ => panic!("expected error"),
    }
}

#[test]
fn sso_callback_rejects_non_sso_and_other_schemes() {
    assert!(parse_sso_callback("sure://app.example.com/accounts").is_none());
    assert!(parse_sso_callback("sureapp://sso/callback?code=x").is_none());
    assert!(parse_sso_callback("sure://sso/callback").is_none());
}
