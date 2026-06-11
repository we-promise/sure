require "test_helper"

class TaxWorkbook::ParserTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
  end

  test "imports generated template rows" do
    upload = workbook_upload(
      filename: "india_tax_april_2026.xlsx",
      content: TaxWorkbook::TemplateGenerator.new.call
    )

    assert_difference "TaxWorkbookImport.count", 1 do
      result = TaxWorkbook::Parser.new(family: @family, uploaded_by: @user, file: upload).call

      assert result.success?, result.errors.inspect

      import = result.import
      assert_equal "complete", import.status
      assert_equal "Risingstone infra pvt ltd", import.entity_name
      assert_equal "27ABCDE1234F1Z5", import.gstin
      assert_equal "MUMR12345A", import.tan
      assert_equal Date.new(2026, 4, 1), import.tax_period_month
      assert_equal "Q1", import.tax_period_quarter
      assert_equal "GST_TDS", import.metadata["return_type"]
      assert_equal "Google Sheets", import.metadata["source_system"]
      assert_equal "india_tax_april_2026.xlsx", import.metadata["source_file_name"]
      assert_equal(
        {
          "gst_outward_lines" => 1,
          "gst_3b_summary" => 1,
          "gst_hsn_summary" => 1,
          "tds_challans" => 1,
          "tds_deductions" => 1
        },
        import.row_counts
      )

      assert import.source_file.attached?
      assert_equal "india_tax_april_2026.xlsx", import.source_file.filename.to_s

      assert_equal 1, import.gst_outward_lines.count
      assert_equal 1, import.gst3b_summaries.count
      assert_equal 1, import.gst_hsn_summaries.count
      assert_equal 1, import.tds_challans.count
      assert_equal 1, import.tds_deductions.count

      challan = import.tds_challans.first
      deduction = import.tds_deductions.first

      assert_equal @family, import.family
      assert_equal import.id, challan.tax_workbook_import_id
      assert_equal import.id, deduction.tax_workbook_import_id
      assert_equal challan, deduction.tds_challan
      assert_equal "CH-APR-001", deduction.challan_ref
    end
  end

  test "stores validation errors for invalid sheet headers without parsed rows" do
    upload = workbook_upload(
      filename: "india_tax_invalid_headers.xlsx",
      content: workbook_with_invalid_headers
    )

    assert_difference "TaxWorkbookImport.count", 1 do
      result = TaxWorkbook::Parser.new(family: @family, uploaded_by: @user, file: upload).call

      assert_not result.success?

      import = result.import
      assert_predicate import, :persisted?
      assert_equal "failed", import.status
      assert import.source_file.attached?
      assert_equal({}, result.import.row_counts)
      assert_empty import.gst_outward_lines
      assert_empty import.gst3b_summaries
      assert_empty import.gst_hsn_summaries
      assert_empty import.tds_challans
      assert_empty import.tds_deductions
      assert_includes import.validation_errors.map { |error| error["sheet"] }, "gst_outward_lines"
      assert_includes import.validation_errors.map { |error| error["message"] }, "Headers do not match template"
    end
  end

  private
    def workbook_upload(filename:, content:)
      uploaded_file(
        filename: filename,
        content_type: TaxWorkbookImport::XLSX_CONTENT_TYPE,
        content: content
      )
    end

    def workbook_with_invalid_headers
      package = Axlsx::Package.new(author: "Sure")

      TaxWorkbook::Template::SHEET_NAMES.each do |sheet_name|
        headers = if sheet_name == "gst_outward_lines"
          TaxWorkbook::Template.headers_for(sheet_name).dup.tap { |value| value[1] = "Invoice No" }
        else
          TaxWorkbook::Template.headers_for(sheet_name)
        end

        package.workbook.add_worksheet(name: sheet_name) do |sheet|
          sheet.add_row headers
          sheet.add_row TaxWorkbook::Template.sample_for(sheet_name)
        end
      end

      package.to_stream.read
    end
end
