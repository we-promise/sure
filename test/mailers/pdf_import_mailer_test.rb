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
end
