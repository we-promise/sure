require "test_helper"

class CsvSanitizerTest < ActiveSupport::TestCase
  test "prefixes formula-triggering values so spreadsheets treat them as text" do
    {
      "=SUM(A1)" => "'=SUM(A1)",
      "+cmd|calc" => "'+cmd|calc",
      "-1+1" => "'-1+1",
      "@evil" => "'@evil",
      "\t=SUM(A1)" => "'\t=SUM(A1)",
      "\r=SUM(A1)" => "'\r=SUM(A1)",
      "\n=SUM(A1)" => "'\n=SUM(A1)"
    }.each do |input, expected|
      assert_equal expected, CsvSanitizer.sanitize(input), "failed for #{input.inspect}"
    end
  end

  test "leaves ordinary values alone" do
    [ "hello", "Groceries", "123", "a=b", "" ].each do |safe|
      assert_equal safe, CsvSanitizer.sanitize(safe)
    end
  end

  test "passes non-string values through untouched" do
    assert_nil CsvSanitizer.sanitize(nil)
    assert_equal 42, CsvSanitizer.sanitize(42)
    assert_equal BigDecimal("-1.5"), CsvSanitizer.sanitize(BigDecimal("-1.5"))
  end

  test "sanitizes every cell of a row" do
    assert_equal [ "'=a", "b", nil, 3 ], CsvSanitizer.sanitize_row([ "=a", "b", nil, 3 ])
  end

  test "unescape reverses the escape so an export can be imported again" do
    [ "=SUM(A1)", "+cmd|calc", "-1.5x leverage", "@home", "\t=SUM(A1)" ].each do |original|
      assert_equal original, CsvSanitizer.unescape(CsvSanitizer.sanitize(original)),
        "failed to round-trip #{original.inspect}"
    end
  end

  test "unescape leaves quotes that are part of the value alone" do
    [ "'tis the season", "'quoted'", "O'Brien", "'", "" ].each do |value|
      assert_equal value, CsvSanitizer.unescape(value)
    end
  end

  test "unescape passes non-string values through untouched" do
    assert_nil CsvSanitizer.unescape(nil)
    assert_equal 42, CsvSanitizer.unescape(42)
  end
end
