use sure_desktop_lib::deep_link::parse;

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
