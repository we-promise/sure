require "test_helper"

class CurrencyNormalizableTest < ActiveSupport::TestCase
  # Create a test class that includes the concern
  class TestClass
    include CurrencyNormalizable

    # Expose private method for testing
    def test_parse_currency(value)
      parse_currency(value)
    end
  end

  setup do
    @parser = TestClass.new
  end

  test "parse_currency normalizes lowercase to uppercase" do
    assert_equal "USD", @parser.test_parse_currency("usd")
    assert_equal "EUR", @parser.test_parse_currency("eur")
    assert_equal "GBP", @parser.test_parse_currency("gbp")
  end

  test "parse_currency handles whitespace" do
    assert_equal "USD", @parser.test_parse_currency("  usd  ")
    assert_equal "EUR", @parser.test_parse_currency("\teur\n")
  end

  test "parse_currency returns nil for blank values" do
    assert_nil @parser.test_parse_currency(nil)
    assert_nil @parser.test_parse_currency("")
    assert_nil @parser.test_parse_currency("   ")
  end

  test "parse_currency returns nil for invalid format" do
    assert_nil @parser.test_parse_currency("US")      # Too short
    assert_nil @parser.test_parse_currency("USDD")    # Too long
    assert_nil @parser.test_parse_currency("123")     # Numbers
    assert_nil @parser.test_parse_currency("US1")     # Mixed
  end

  test "parse_currency returns nil for XXX (no currency code)" do
    # XXX is ISO 4217 for "no currency" but not valid for monetary operations
    assert_nil @parser.test_parse_currency("XXX")
    assert_nil @parser.test_parse_currency("xxx")
  end

  test "parse_currency returns nil for unknown 3-letter codes" do
    # These are 3 letters but not recognized currencies
    assert_nil @parser.test_parse_currency("ZZZ")
    assert_nil @parser.test_parse_currency("ABC")
  end

  test "parse_currency accepts valid ISO currencies" do
    # Common currencies
    assert_equal "USD", @parser.test_parse_currency("USD")
    assert_equal "EUR", @parser.test_parse_currency("EUR")
    assert_equal "GBP", @parser.test_parse_currency("GBP")
    assert_equal "JPY", @parser.test_parse_currency("JPY")
    assert_equal "CHF", @parser.test_parse_currency("CHF")
    assert_equal "CAD", @parser.test_parse_currency("CAD")
    assert_equal "AUD", @parser.test_parse_currency("AUD")

    # Less common but valid currencies
    assert_equal "PLN", @parser.test_parse_currency("PLN")
    assert_equal "SEK", @parser.test_parse_currency("SEK")
    assert_equal "NOK", @parser.test_parse_currency("NOK")
  end
end
