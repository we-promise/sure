use sure_desktop_lib::window::print_report_server;
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
