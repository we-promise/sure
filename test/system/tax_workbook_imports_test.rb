require "application_system_test_case"

class TaxWorkbookImportsTest < ApplicationSystemTestCase
  setup do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    ensure_tailwind_build
    sign_in users(:family_admin)

    @fixture_path = Rails.root.join("tmp", "tax_workbook_system_test.xlsx")
    File.binwrite(@fixture_path, realistic_tax_workbook_content)
  end

  teardown do
    File.delete(@fixture_path) if File.exist?(@fixture_path)
  end

  test "uploads and searches tax workbook records" do
    visit tax_workbook_imports_path

    attach_file "tax_workbook_import_file", @fixture_path
    click_button I18n.t("tax_workbook_imports.index.upload_button")

    assert_text I18n.t("tax_workbook_imports.create.success")
    assert_text "Risingstone Infra Pvt Ltd"

    visit tax_records_path
    fill_in I18n.t("tax_records.index.search_label"), with: "RS-APR-002"
    find("input[name='q[search]']").send_keys(:enter)

    assert_text "RS-APR-002"
    assert_text "29ABCDE1234F1Z7"
  end
end
