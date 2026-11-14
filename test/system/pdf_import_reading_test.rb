require "application_system_test_case"

# PDF reading in the browser: "Read as" on the upload form, the review flag on
# an extraction that failed its checks, and confirming its publish.
class PdfImportReadingTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    sign_in @user = users(:family_admin)
    use_ai_routes(extract_pdf: %w[gpu/qwen3-8b])
    adapter = mock("vector_store_adapter")
    adapter.stubs(:supported_extensions).returns(%w[.pdf .txt])
    VectorStore::Registry.stubs(:adapter).returns(adapter)
  end

  test "an upload is read the way chosen, and a way the route can't do is greyed out" do
    visit new_import_path(type: "PdfImport")

    select = find("select[name='import[read_as]']")
    assert select.find("option[value=images]").disabled?
    assert_not select.find("option[value=text]").disabled?
    select.select "Text"
    attach_file "import[import_file]", file_fixture("imports/sample_bank_statement.pdf"), make_visible: true

    assert_text I18n.t("imports.create.pdf_processing")
    assert_equal "text", PdfImport.order(:created_at).last.read_as
  end

  test "a flagged extraction lists its failed checks and asks before publishing" do
    import = imports(:pdf_with_rows)
    import.update!(account: accounts(:depository), read_with: "text",
                   extraction_checks: { "passed" => false, "reconciles" => false, "amounts_in_source" => true })
    PdfImport.any_instance.stubs(uploaded?: true, publishable?: true)

    visit import_path(import)

    assert_text I18n.t("imports.pdf_import.review_flag.title")
    assert_text I18n.t("imports.pdf_import.review_flag.checks.reconciles")
    click_on I18n.t("imports.pdf_import.publish_transactions", count: import.rows_count)
    assert_text I18n.t("imports.pdf_import.review_flag.confirm_title")
  end
end
