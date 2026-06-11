require "test_helper"

module TaxWorkbook
  class TemplateGeneratorTest < ActiveSupport::TestCase
    test "generates workbook with required sheets" do
      xlsx = TaxWorkbook::TemplateGenerator.new.call
      tempfile = Tempfile.new([ "tax-template", ".xlsx" ])
      tempfile.binmode
      tempfile.write(xlsx)
      tempfile.rewind

      workbook = SimpleXlsxReader.open(tempfile.path)

      sheets = workbook.sheets.index_by(&:name)
      assert_equal TaxWorkbook::Template::SHEET_NAMES, sheets.keys
      assert_equal TaxWorkbook::Template.headers_for("meta"), sheets.fetch("meta").rows.slurp.first
      assert_equal TaxWorkbook::Template.headers_for("tds_deductions"), sheets.fetch("tds_deductions").rows.slurp.first
    ensure
      tempfile&.close!
    end
  end
end
