use sure_desktop_lib::servers::{
    base_candidates, base_covers, health_check_url, is_healthy_status, normalize_server_url,
    MAX_BASE_CANDIDATES,
};

#[test]
fn normalizes_bare_host_to_https_origin() {
    assert_eq!(normalize_server_url("app.example.com").unwrap(), "https://app.example.com");
}

#[test]
fn preserves_explicit_http_scheme_and_port() {
    assert_eq!(normalize_server_url("http://localhost:3000/").unwrap(), "http://localhost:3000");
}

#[test]
fn keeps_the_sub_path_a_server_is_mounted_under() {
    assert_eq!(normalize_server_url("https://s.example.com/sure").unwrap(), "https://s.example.com/sure");
}

#[test]
fn strips_trailing_slash_query_and_fragment() {
    assert_eq!(normalize_server_url("https://s.example.com/sure/").unwrap(), "https://s.example.com/sure");
    assert_eq!(normalize_server_url("https://s.example.com/?a=1#x").unwrap(), "https://s.example.com");
}

#[test]
fn rejects_empty_input() {
    assert!(normalize_server_url("   ").is_err());
}

#[test]
fn builds_health_url() {
    assert_eq!(health_check_url("https://s.example.com"), "https://s.example.com/up");
    assert_eq!(health_check_url("https://s.example.com/sure"), "https://s.example.com/sure/up");
}

#[test]
fn origin_is_its_own_only_candidate() {
    assert_eq!(base_candidates("https://s.example.com"), vec!["https://s.example.com"]);
}

#[test]
fn walks_a_pasted_deep_link_back_up_to_the_origin() {
    assert_eq!(
        base_candidates("https://s.example.com/sessions/new"),
        vec![
            "https://s.example.com/sessions/new",
            "https://s.example.com/sessions",
            "https://s.example.com",
        ]
    );
}

#[test]
fn keeps_the_port_on_every_candidate() {
    assert_eq!(
        base_candidates("http://localhost:3000/sure"),
        vec!["http://localhost:3000/sure", "http://localhost:3000"]
    );
}

#[test]
fn a_base_covers_itself_and_what_sits_under_it() {
    assert!(base_covers("https://s.example.com", "https://s.example.com"));
    assert!(base_covers("https://s.example.com", "https://s.example.com/accounts"));
    assert!(base_covers("https://s.example.com/sure", "https://s.example.com/sure/accounts"));
}

#[test]
fn a_base_does_not_cover_a_lookalike_host_or_a_sibling_path() {
    assert!(!base_covers("https://s.example.com", "https://s.example.com.evil.test/accounts"));
    assert!(!base_covers("https://s.example.com/sure", "https://s.example.com/surely"));
    assert!(!base_covers("https://s.example.com/sure", "https://s.example.com"));
}

#[test]
fn caps_candidates_but_always_keeps_the_origin() {
    let candidates = base_candidates("https://s.example.com/a/b/c/d/e");
    assert_eq!(candidates.len(), MAX_BASE_CANDIDATES);
    assert_eq!(candidates[0], "https://s.example.com/a/b/c/d/e");
    assert_eq!(candidates.last().unwrap(), "https://s.example.com");
}

// The cap drops from the deep middle, never from the shallow end: a mount point
// is shallow, so a deep link pasted from a mounted server must still probe it.
#[test]
fn capping_keeps_the_shallow_mount_a_deep_link_sits_under() {
    let candidates = base_candidates("https://s.example.com/sure/transactions/123/edit");
    assert_eq!(candidates.len(), MAX_BASE_CANDIDATES);
    assert!(
        candidates.contains(&"https://s.example.com/sure".to_string()),
        "the mount base was dropped: {candidates:?}"
    );
    assert_eq!(candidates[0], "https://s.example.com/sure/transactions/123/edit");
    assert_eq!(candidates.last().unwrap(), "https://s.example.com");
}

#[test]
fn only_200_is_healthy() {
    assert!(is_healthy_status(200));
    assert!(!is_healthy_status(302));
    assert!(!is_healthy_status(500));
}
