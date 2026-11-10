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

  test "successful search upload reports pending indexing without promising future context" do
    mail = PdfImportMailer.with(user: @user, pdf_import: @pdf_import, document_uploaded_for_search: true).next_steps

    [ mail.html_part, mail.text_part ].each do |part|
      assert_includes part.body.decoded, I18n.t("pdf_import_mailer.next_steps.document_search_upload_note")
      assert_not_includes part.body.decoded, I18n.t("pdf_import_mailer.next_steps.document_reference_only_note")
      assert_not_includes part.body.decoded, "future AI conversations"
    end
  end

  %w[bank_statement financial_document].each do |document_type|
    test "#{document_type} email does not promise document search without a successful upload" do
      @pdf_import.document_type = document_type
      mail = PdfImportMailer.with(user: @user, pdf_import: @pdf_import, document_uploaded_for_search: false).next_steps

      [ mail.html_part, mail.text_part ].each do |part|
        assert_includes part.body.decoded, I18n.t("pdf_import_mailer.next_steps.document_reference_only_note")
        assert_includes part.body.decoded, I18n.t("pdf_import_mailer.next_steps.option_keep_import_reference")
        assert_not_includes part.body.decoded, I18n.t("pdf_import_mailer.next_steps.document_search_upload_note")
        assert_not_includes part.body.decoded, "future AI conversations"
      end
    end
  end

  test "previously queued emails without an upload result make no search claim" do
    mail = PdfImportMailer.with(user: @user, pdf_import: @pdf_import).next_steps

    [ mail.html_part, mail.text_part ].each do |part|
      assert_includes part.body.decoded, I18n.t("pdf_import_mailer.next_steps.document_reference_only_note")
      assert_not_includes part.body.decoded, "future AI conversations"
    end
  end

  test "untranslated search status falls back to English instead of old context claims" do
    I18n.with_locale(:fr) do
      mail = PdfImportMailer.with(user: @user, pdf_import: @pdf_import, document_uploaded_for_search: false).next_steps

      [ mail.html_part, mail.text_part ].each do |part|
        assert_includes part.body.decoded, I18n.t("pdf_import_mailer.next_steps.document_reference_only_note", locale: :en)
        assert_not_includes part.body.decoded, I18n.t("pdf_import_mailer.next_steps.document_stored_note")
        assert_not_includes part.body.decoded, I18n.t("pdf_import_mailer.next_steps.option_keep_reference")
      end
    end
  end
end
