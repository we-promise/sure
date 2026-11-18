require "test_helper"

class PdfImportMailerTest < ActionMailer::TestCase
  setup do
    @user = users(:family_admin)
    @pdf_import = imports(:pdf_processed)
  end

  test "next_steps email is sent to user" do
    mail = PdfImportMailer.with(user: @user, pdf_import: @pdf_import).next_steps

    assert_equal I18n.t(
      "pdf_import_mailer.next_steps.subject",
      product_name: Rails.configuration.x.product_name
    ), mail.subject
    assert_equal [ @user.email ], mail.to
    assert_includes mail.subject, "analyzed"
  end

  test "next_steps email contains document summary" do
    mail = PdfImportMailer.with(user: @user, pdf_import: @pdf_import).next_steps

    assert_match @pdf_import.ai_summary, mail.body.encoded
  end
  test "the email describes the reading that queued it, not one a reread made since" do
    reading = { document_type: "bank_statement", summary: "February statement", failed_checks: %w[reconciles] }
    @pdf_import.update!(ai_summary: "a later reading")

    body = PdfImportMailer.with(user: @user, pdf_import: @pdf_import, reading:).next_steps.body.encoded

    assert_match "February statement", body
    assert_match I18n.t("pdf_import_mailer.next_steps.review_flag_note").first(40), body
  end

  test "a statement whose balances weren't found is unchecked, not failed" do
    reading = { document_type: "bank_statement", summary: "s", failed_checks: %w[balances] }

    body = PdfImportMailer.with(user: @user, pdf_import: @pdf_import, reading:).next_steps.body.encoded

    assert_match I18n.t("pdf_import_mailer.next_steps.unchecked_note").first(40), body
    assert_no_match I18n.t("pdf_import_mailer.next_steps.review_flag_note").first(40), body
  end
end
