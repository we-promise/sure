require "test_helper"

class TaxWorkbookImportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    ensure_tailwind_build
    sign_in @admin = users(:family_admin)
    @import = tax_workbook_imports(:april_2026)
  end

  test "admin can view tax workbook imports index" do
    get tax_workbook_imports_url

    assert_response :success
    assert_select "h1", text: I18n.t("tax_workbook_imports.index.title")
    assert_select "input#tax_workbook_import_file"
  end

  test "non admin cannot view tax workbook imports index" do
    sign_in users(:family_member)

    get tax_workbook_imports_url

    assert_redirected_to root_url
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
  end

  test "admin can download template" do
    get template_tax_workbook_imports_url

    assert_response :success
    assert_equal TaxWorkbookImport::XLSX_CONTENT_TYPE, response.media_type
    assert_match(/attachment;/, response.headers["Content-Disposition"])
  end

  test "admin can upload valid workbook" do
    upload = uploaded_file(
      filename: "india_tax_april_2026.xlsx",
      content_type: TaxWorkbookImport::XLSX_CONTENT_TYPE,
      content: TaxWorkbook::TemplateGenerator.new.call
    )

    assert_difference "TaxWorkbookImport.count", 1 do
      post tax_workbook_imports_url, params: {
        tax_workbook_import: {
          file: upload
        }
      }
    end

    created_import = TaxWorkbookImport.order(:created_at).last
    assert_redirected_to tax_workbook_import_url(created_import)
    assert_equal I18n.t("tax_workbook_imports.create.success"), flash[:notice]
  end
end
