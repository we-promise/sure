# frozen_string_literal: true

require "test_helper"

class CsvFormulaSanitizerTest < ActiveSupport::TestCase
  test "prefixes spreadsheet formula characters" do
    assert_equal "'=1+1", CsvFormulaSanitizer.escape("=1+1")
    assert_equal "'+cmd", CsvFormulaSanitizer.escape("+cmd")
    assert_equal "'-10", CsvFormulaSanitizer.escape("-10")
    assert_equal "'@sum", CsvFormulaSanitizer.escape("@sum")
    assert_equal "'\t=IMPORTDATA(\"http://evil\")", CsvFormulaSanitizer.escape("\t=IMPORTDATA(\"http://evil\")")
    assert_equal "'\r=1+1", CsvFormulaSanitizer.escape("\r=1+1")
  end

  test "leaves safe labels unchanged" do
    assert_equal "Groceries", CsvFormulaSanitizer.escape("Groceries")
  end
end
