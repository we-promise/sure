require "test_helper"

class ImportDocumentCapabilitiesTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    sign_in @user = users(:family_admin)
    ensure_tailwind_build
  end

  %w[anthropic openrouter].each do |provider|
    test "family #{provider} keeps the PDF analysis option without searchable file upload" do
      @user.family.create_ai_configuration!(provider: provider, api_key: "synthetic-family-key", model: provider == "openrouter" ? "openai/gpt-4.1-mini" : Provider::Anthropic::DEFAULT_MODEL)

      get new_import_url

      assert_response :success
      assert_select "input[type=file][name='import[import_file]'][accept='.pdf']", count: 1
      assert_select "span", text: I18n.t("imports.new.import_pdf_analysis_description")
      assert_select "span", text: I18n.t("imports.new.import_file_description"), count: 0
    end

    test "family #{provider} queues PDF processing from the document upload option" do
      @user.family.create_ai_configuration!(provider: provider, api_key: "synthetic-family-key", model: provider == "openrouter" ? "openai/gpt-4.1-mini" : Provider::Anthropic::DEFAULT_MODEL)
      Family.any_instance.expects(:upload_document).never

      assert_difference "PdfImport.count", 1 do
        assert_enqueued_jobs 1, only: ProcessPdfJob do
          post imports_url, params: {
            import: { type: "DocumentImport", import_file: file_fixture_upload("imports/sample_bank_statement.pdf", "application/pdf") }
          }
        end
      end

      assert_redirected_to import_url(PdfImport.order(:created_at).last)
      assert_equal I18n.t("imports.create.pdf_processing"), flash[:notice]
    end

    test "family #{provider} rejects non-PDF document search uploads" do
      @user.family.create_ai_configuration!(provider: provider, api_key: "synthetic-family-key", model: provider == "openrouter" ? "openai/gpt-4.1-mini" : Provider::Anthropic::DEFAULT_MODEL)
      Family.any_instance.expects(:upload_document).never

      assert_no_difference [ "Import.count", "FamilyDocument.count" ] do
        post imports_url, params: {
          import: { type: "DocumentImport", import_file: file_fixture_upload("imports/valid.csv", "text/csv") }
        }
      end

      assert_redirected_to new_import_url
      assert_equal I18n.t("imports.create.document_provider_not_configured"), flash[:alert]
    end
  end

  test "family OpenAI retains the searchable document upload option" do
    @user.family.create_ai_configuration!(provider: "openai", api_key: "synthetic-family-key")

    get new_import_url

    assert_response :success
    assert_select "input[type=file][name='import[import_file]'][accept*='.pdf'][accept*='.txt']", count: 1
    assert_select "span", text: I18n.t("imports.new.import_file_description")
  end

  test "PDF upload still validates the file header when document search is unavailable" do
    @user.family.create_ai_configuration!(provider: "anthropic", api_key: "synthetic-family-key")

    assert_no_difference "Import.count" do
      assert_no_enqueued_jobs only: ProcessPdfJob do
        post imports_url, params: {
          import: { type: "DocumentImport", import_file: uploaded_file(filename: "not-a-pdf.pdf", content_type: "application/pdf", content: "invalid") }
        }
      end
    end

    assert_redirected_to new_import_url
    assert_equal I18n.t("imports.create.invalid_pdf"), flash[:alert]
  end
end
