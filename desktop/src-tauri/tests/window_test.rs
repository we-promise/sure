use sure_desktop_lib::servers::{base_covers, normalize_server_url};
use sure_desktop_lib::window::{popup_action, print_report_server, PopupAction, RefusedDownloads};
use url::Url;

#[test]
fn identifies_print_reports_with_filters_and_server_mounts() {
    for (url, expected) in [
        (
            "https://sure.example.com/reports/print?period_type=monthly",
            "https://sure.example.com",
        ),
        (
            "http://localhost:3000/sure/reports/print?start_date=2026-09-01&end_date=2026-09-09",
            "http://localhost:3000/sure",
        ),
        (
            "https://sure.example.com/nested/sure/reports/print",
            "https://sure.example.com/nested/sure",
        ),
    ] {
        assert_eq!(
            print_report_server(&Url::parse(url).unwrap()).as_deref(),
            Some(expected)
        );
    }
}

#[test]
fn rejects_other_popup_routes_and_non_server_urls() {
    for url in [
        "https://sure.example.com/reports",
        "https://sure.example.com/reports/print/other",
        "https://sure.example.com/reports/printable",
        "https://sure.example.com/accounts?next=/reports/print",
        "https://user:password@sure.example.com/reports/print",
        "file:///reports/print",
        "javascript:window.print()",
        "about:blank",
    ] {
        assert!(
            print_report_server(&Url::parse(url).unwrap()).is_none(),
            "accepted {url}"
        );
    }
}

// Mirrors servers::is_known_server without reading the saved server list.
fn saved_server(url: &str) -> bool {
    normalize_server_url(url).is_ok_and(|url| {
        ["https://sure.example.com", "https://home.example.com/sure"]
            .iter()
            .any(|base| base_covers(base, &url))
    })
}

fn action(url: &str, opener_trusted: bool) -> PopupAction {
    popup_action(&Url::parse(url).unwrap(), opener_trusted, saved_server)
}

#[test]
fn opens_saved_server_pages_in_a_sure_window() {
    for url in [
        "https://sure.example.com/reports/print?period_type=monthly",
        "https://sure.example.com/transactions/1/attachments/2?disposition=inline",
        "https://sure.example.com/privacy",
        "https://home.example.com/sure/reports/print",
    ] {
        assert_eq!(action(url, true), PopupAction::ServerWindow, "{url}");
    }
}

#[test]
fn opens_other_websites_in_the_browser() {
    for url in [
        "https://app.snaptrade.com/device?user_code=ABCD-1234",
        "https://discord.gg/36ZGBsxYEK",
        "http://example.org/help",
        "https://sure.example.com.evil.test/reports/print",
        "http://sure.example.com/reports/print",
        "https://home.example.com/other",
        "https://home.example.com/surely",
    ] {
        assert_eq!(action(url, true), PopupAction::Browser, "{url}");
    }
}

#[test]
fn ignores_popups_from_pages_outside_saved_servers() {
    for url in [
        "https://sure.example.com/reports/print",
        "https://app.snaptrade.com/device",
    ] {
        assert_eq!(action(url, false), PopupAction::Deny, "{url}");
    }
}

#[test]
fn ignores_non_web_schemes_and_credentials() {
    for url in [
        "file:///etc/passwd",
        "javascript:alert(1)",
        "about:blank",
        "data:text/html,hello",
        "mailto:support@example.com",
        "sure://sure.example.com/accounts",
        "x-apple.systempreferences:com.apple.preference.security",
        "https://user:password@sure.example.com/reports/print",
        "https://user@example.org/",
    ] {
        assert_eq!(action(url, true), PopupAction::Deny, "{url}");
    }
}

// The decision made when a download starts holds until it finishes, whatever
// page the window has navigated to in between.
#[test]
fn reports_every_download_outcome_except_refused_downloads() {
    let downloads = RefusedDownloads::default();
    let export = Url::parse("https://sure.example.com/reports/export_transactions.csv").unwrap();
    let tracker = Url::parse("https://tracker.example/file.zip").unwrap();

    assert!(downloads.remember(&export, true));
    assert!(!downloads.remember(&tracker, false));

    assert!(
        downloads.should_report(&export, false),
        "an allowed download that fails is reported"
    );
    assert!(downloads.should_report(&export, true));
    assert!(
        !downloads.should_report(&tracker, false),
        "a refused download ends quietly"
    );
    assert!(
        downloads.should_report(&tracker, false),
        "each refusal silences only its own failure"
    );
}
