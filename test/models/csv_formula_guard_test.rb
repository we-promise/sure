require "test_helper"

class CsvFormulaGuardTest < ActiveSupport::TestCase
  test "prefixes a quote when text starts with a formula character" do
    [ "=HYPERLINK(\"http://example.invalid\")", "+1+1", "-1+1", "@SUM(1)", "\t=1", "\r=1", "\n=1" ].each do |value|
      assert_equal "'#{value}", CsvFormulaGuard.escape(value)
    end
  end

  test "leaves ordinary text, blanks and non-strings untouched" do
    [ "Groceries", "", "a=b", " =1", "'plain", "''plain", 12, -12.5 ].each do |value|
      assert_equal value, CsvFormulaGuard.escape(value)
    end
  end

  test "keeps values that differ only by leading apostrophes distinct" do
    assert_equal "'=x", CsvFormulaGuard.escape("=x")
    assert_equal "''=x", CsvFormulaGuard.escape("'=x")
    assert_equal "'''-1", CsvFormulaGuard.escape("''-1")
  end

  test "nil passes through" do
    assert_nil CsvFormulaGuard.escape(nil)
  end
end
