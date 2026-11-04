use sure_desktop_lib::attachments::is_attachment;

#[test]
fn saves_responses_marked_as_attachments() {
    for header in [
        "attachment",
        "attachment; filename=\"statement.pdf\"; filename*=UTF-8''statement.pdf",
        "Attachment; filename=transactions_breakdown.csv",
        "  attachment ;filename=sample.csv",
    ] {
        assert!(is_attachment(header), "{header}");
    }
}

#[test]
fn displays_every_other_response() {
    for header in [
        "",
        "inline",
        "inline; filename=\"attachment.pdf\"",
        "attachments",
        "form-data; name=\"attachment\"",
    ] {
        assert!(!is_attachment(header), "{header}");
    }
}
