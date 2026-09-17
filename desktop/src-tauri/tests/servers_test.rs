use sure_desktop_lib::servers::{
    base_candidates, base_covers, health_check_url, is_healthy_status, normalize_server_url,
    MAX_MOUNT_DEPTH,
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

// A deep link is probed against the address as typed and against every mount
// depth up to MAX_MOUNT_DEPTH — no supported mount is skipped, at any depth.
#[test]
fn probes_the_typed_address_and_every_supported_mount_depth() {
    assert_eq!(
        base_candidates("https://s.example.com/a/b/c/d/e"),
        vec![
            "https://s.example.com/a/b/c/d/e",
            "https://s.example.com/a/b/c",
            "https://s.example.com/a/b",
            "https://s.example.com/a",
            "https://s.example.com",
        ]
    );
}

#[test]
fn probes_the_shallow_mount_a_deep_link_sits_under() {
    let candidates = base_candidates("https://s.example.com/sure/transactions/123/edit");
    assert!(
        candidates.contains(&"https://s.example.com/sure".to_string()),
        "the mount base was dropped: {candidates:?}"
    );
    assert_eq!(candidates[0], "https://s.example.com/sure/transactions/123/edit");
    assert_eq!(candidates.last().unwrap(), "https://s.example.com");
}

#[test]
fn a_multi_segment_mount_is_reached_through_a_deep_link() {
    let candidates = base_candidates("https://s.example.com/apps/finance/sure/accounts/42");
    assert!(
        candidates.contains(&"https://s.example.com/apps/finance/sure".to_string()),
        "a {MAX_MOUNT_DEPTH}-segment mount was dropped: {candidates:?}"
    );
}

#[test]
fn the_walk_stays_bounded() {
    let deep = format!("https://s.example.com/{}", vec!["seg"; 40].join("/"));
    assert_eq!(base_candidates(&deep).len(), MAX_MOUNT_DEPTH + 2); // typed + depths 3..0
}

#[test]
fn only_200_is_healthy() {
    assert!(is_healthy_status(200));
    assert!(!is_healthy_status(302));
    assert!(!is_healthy_status(500));
}
