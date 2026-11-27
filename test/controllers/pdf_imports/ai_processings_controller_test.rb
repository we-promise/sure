require "test_helper"

class PdfImports::AiProcessingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @import = imports(:pdf)
  end

  test "stops an importing pdf import" do
    @import.update!(status: :importing, error: "an old error", reread_token: "attempt")

    delete pdf_import_ai_processing_path(@import)

    assert_redirected_to import_path(@import)
    assert_equal I18n.t("pdf_imports.ai_processings.destroy.stopped"), flash[:notice]
    @import.reload
    assert @import.cancelled?
    assert_nil @import.error
    assert_nil @import.reread_token
  end

  test "refuses to stop an import that is not processing" do
    delete pdf_import_ai_processing_path(@import)

    assert_equal I18n.t("pdf_imports.ai_processings.destroy.not_processing"), flash[:alert]
    assert @import.reload.pending?
  end

  test "cannot stop another family's import" do
    @import.update!(status: :importing)
    sign_in users(:empty)

    delete pdf_import_ai_processing_path(@import)

    assert_response :not_found
    assert @import.reload.importing?
  end

  test "a guest cannot stop a legacy import without a statement" do
    @import.update!(status: :importing)
    guest = users(:family_member)
    guest.update!(role: :guest)
    sign_in guest

    delete pdf_import_ai_processing_path(@import)

    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
    assert @import.reload.importing?
  end

  test "a member can stop an import whose statement they manage" do
    import = statement_import(account: nil)
    import.update!(status: :importing)
    sign_in users(:family_member)

    delete pdf_import_ai_processing_path(import)

    assert_redirected_to import_path(import)
    assert import.reload.cancelled?
  end

  test "a member with only read access to a statement cannot stop its import" do
    account = accounts(:credit_card)
    import = statement_import(account: account)
    import.update!(status: :importing)
    sign_in users(:family_member)

    delete pdf_import_ai_processing_path(import)

    assert_redirected_to account_url(account)
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
    assert import.reload.importing?
  end

  private
    def statement_import(account:)
      statement = AccountStatement.create_from_upload!(
        family: @user.family,
        account: account,
        file: uploaded_file(
          filename: "statement.pdf",
          content_type: "application/pdf",
          content: file_fixture("imports/sample_bank_statement.pdf").binread
        )
      )
      PdfImport.create_from_statement!(statement: statement)
    end
end
