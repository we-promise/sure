require "test_helper"

class Import::XlsxWorkbookTest < ActiveSupport::TestCase
  setup do
    path = Rails.root.join("test/fixtures/files/imports/sample_bank_export.xlsx")
    @workbook = Import::XlsxWorkbook.open(File.binread(path))
  end

  test "lists sheets in workbook order, resolving worksheet parts via rels" do
    assert_equal [
      "Vos comptes",
      "Cpt 02619 00099999901",
      "CB 02619 00099999901 # 052026",
      "hidden_data"
    ], @workbook.sheet_names
  end

  test "flags the very-hidden manifest sheet as hidden" do
    assert @workbook.sheet("hidden_data").hidden?
    assert_not @workbook.sheet("Vos comptes").hidden?
    assert_equal [ "Vos comptes", "Cpt 02619 00099999901", "CB 02619 00099999901 # 052026" ],
                 @workbook.visible_sheets.map(&:name)
  end

  test "reads shared strings and numeric cell values into a 1-based matrix" do
    matrix = @workbook.cell_matrix("Vos comptes")

    assert_equal "Compte", matrix[3][1]
    assert_equal "R.I.B.", matrix[3][2]
    assert_equal "10278 02619 00099999901", matrix[4][2]
    assert_equal "100", matrix[4][3].to_s.sub(/\.0\z/, "")
  end

  test "excel_serial_to_date converts serials to dates" do
    assert_equal Date.new(2024, 12, 31), Import::XlsxWorkbook.excel_serial_to_date(45657)
    assert_nil Import::XlsxWorkbook.excel_serial_to_date(nil)
  end

  test "column_letter_to_index handles single and multi-letter columns" do
    assert_equal 1, Import::XlsxWorkbook.column_letter_to_index("A")
    assert_equal 5, Import::XlsxWorkbook.column_letter_to_index("E")
    assert_equal 27, Import::XlsxWorkbook.column_letter_to_index("AA")
  end

  test "raises a friendly error for an unknown sheet" do
    assert_raises(Import::XlsxWorkbook::Error) do
      @workbook.cell_matrix("does-not-exist")
    end
  end
end
