require "test_helper"

class TaxRecordsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    ensure_tailwind_build
    sign_in @admin = users(:family_admin)
    @family = @admin.family
    @import = tax_workbook_imports(:april_2026)
  end

  test "admin can view tax records index" do
    get tax_records_url

    assert_response :success
    assert_select "h1", text: I18n.t("tax_records.index.title")
    assert_select "input[name='q[search]']"
  end

  test "non admin cannot view tax records index" do
    sign_in users(:family_member)

    get tax_records_url

    assert_redirected_to root_url
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
  end

  test "tax records index can search gst outward lines by invoice number" do
    GstOutwardLine.create!(
      family: @family,
      tax_workbook_import: @import,
      source_row_number: 999,
      tax_period_month: Date.new(2026, 4, 1),
      gstin: "27ABCDE1234F1Z5",
      gstr1_table_code: "4A",
      invoice_no: "INV-SEARCH",
      invoice_date: Date.new(2026, 4, 10),
      recipient_gstin_or_uin: "29ABCDE1234F1Z7",
      taxable_value: 2500,
      igst: 450,
      cgst: 0,
      sgst_ugst: 0,
      cess: 0
    )

    get tax_records_url, params: { q: { search: "INV-SEARCH" } }

    assert_response :success
    assert_includes response.body, "INV-SEARCH"
  end
end
