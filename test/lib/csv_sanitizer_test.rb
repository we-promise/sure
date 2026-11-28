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

  test "leaves plain numbers alone, signed ones included" do
    [ "-42.5", "-1200.0", "+3", "-0.0001", "-1e3", "-7" ].each do |number|
      assert_equal number, CsvSanitizer.sanitize(number), "failed for #{number.inspect}"
    end
  end

  test "still escapes a value that only starts like a number" do
    {
      "-1+1" => "'-1+1",
      "-2*cmd|' /C calc'!A0" => "'-2*cmd|' /C calc'!A0",
      "+1)" => "'+1)",
      "-42.5\n=1" => "'-42.5\n=1"
    }.each do |input, expected|
      assert_equal expected, CsvSanitizer.sanitize(input), "failed for #{input.inspect}"
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

  test "keeps the escape injective for values that already start with apostrophes" do
    {
      "=x" => "'=x",
      "'=x" => "''=x",
      "''-x" => "'''-x",
      "'plain" => "'plain",
      "'-42.5" => "''-42.5"
    }.each do |input, expected|
      assert_equal expected, CsvSanitizer.sanitize(input), "failed for #{input.inspect}"
    end

    inputs = [ "=x", "'=x", "''=x", "x", "'x" ]
    assert_equal inputs.size, inputs.map { |v| CsvSanitizer.sanitize(v) }.uniq.size
  end
end
