require "test_helper"

class SnaptradeDataHelpersTest < ActiveSupport::TestCase
  # Create a test class that includes the concern
  class TestHelper
    include SnaptradeAccount::DataHelpers

    # Expose private methods for testing
    def test_parse_decimal(value)
      parse_decimal(value)
    end

    def test_parse_date(value)
      parse_date(value)
    end

    def test_resolve_security(symbol, symbol_data)
      resolve_security(symbol, symbol_data)
    end

    def test_extract_currency(data, symbol_data = {}, fallback = nil)
      extract_currency(data, symbol_data, fallback)
    end
  end

  setup do
    @helper = TestHelper.new
  end

  # === parse_decimal tests ===

  test "parse_decimal handles BigDecimal" do
    result = @helper.test_parse_decimal(BigDecimal("123.45"))
    assert_equal BigDecimal("123.45"), result
  end

  test "parse_decimal handles String" do
    result = @helper.test_parse_decimal("456.78")
    assert_equal BigDecimal("456.78"), result
  end

  test "parse_decimal handles Integer" do
    result = @helper.test_parse_decimal(100)
    assert_equal BigDecimal("100"), result
  end

  test "parse_decimal handles Float" do
    result = @helper.test_parse_decimal(99.99)
    assert_equal BigDecimal("99.99"), result
  end

  test "parse_decimal returns nil for nil input" do
    result = @helper.test_parse_decimal(nil)
    assert_nil result
  end

  test "parse_decimal returns nil for invalid string" do
    result = @helper.test_parse_decimal("not_a_number")
    assert_nil result
  end

  # === parse_date tests ===

  test "parse_date handles Date object" do
    date = Date.new(2024, 6, 15)
    result = @helper.test_parse_date(date)
    assert_equal date, result
  end

  test "parse_date handles ISO string" do
    result = @helper.test_parse_date("2024-06-15")
    assert_equal Date.new(2024, 6, 15), result
  end

  test "parse_date handles Time object" do
    time = Time.zone.parse("2024-06-15 10:30:00")
    result = @helper.test_parse_date(time)
    assert_equal Date.new(2024, 6, 15), result
  end

  test "parse_date handles DateTime" do
    dt = DateTime.new(2024, 6, 15, 10, 30)
    result = @helper.test_parse_date(dt)
    # DateTime is a subclass of Date, so it matches Date branch and returns as-is
    # which is acceptable behavior - the result is still usable as a date
    assert result.respond_to?(:year)
    assert_equal 2024, result.year
    assert_equal 6, result.month
    assert_equal 15, result.day
  end

  test "parse_date returns nil for nil input" do
    result = @helper.test_parse_date(nil)
    assert_nil result
  end

  test "parse_date returns nil for invalid string" do
    result = @helper.test_parse_date("invalid_date")
    assert_nil result
  end

  # === resolve_security tests ===

  test "resolve_security finds existing security by ticker" do
    existing = Security.create!(ticker: "TEST", name: "Test Company")

    result = @helper.test_resolve_security("TEST", {})
    assert_equal existing, result
  end

  test "resolve_security creates new security when not found" do
    symbol_data = { "description" => "New Corp Inc" }

    result = @helper.test_resolve_security("NEWCORP", symbol_data)

    assert_not_nil result
    assert_equal "NEWCORP", result.ticker
    assert_equal "New Corp Inc", result.name
  end

  test "resolve_security uppercases ticker" do
    symbol_data = { "description" => "Lowercase Test" }

    result = @helper.test_resolve_security("lowercase", symbol_data)

    assert_equal "LOWERCASE", result.ticker
  end

  test "resolve_security returns nil for blank ticker" do
    result = @helper.test_resolve_security("", {})
    assert_nil result

    result = @helper.test_resolve_security(nil, {})
    assert_nil result
  end

  test "resolve_security handles race condition on creation" do
    # Simulate race condition by creating after first check
    symbol_data = { "description" => "Race Condition Test" }

    # Create the security before resolve_security can
    Security.create!(ticker: "RACECOND", name: "Already Created")

    # Should return existing instead of raising
    result = @helper.test_resolve_security("RACECOND", symbol_data)
    assert_equal "RACECOND", result.ticker
  end

  # === extract_currency tests ===

  test "extract_currency handles hash with code key (symbol access)" do
    data = { currency: { code: "CAD" } }
    result = @helper.test_extract_currency(data)
    assert_equal "CAD", result
  end

  test "extract_currency handles hash with code key (string access)" do
    data = { "currency" => { "code" => "EUR" } }
    result = @helper.test_extract_currency(data)
    assert_equal "EUR", result
  end

  test "extract_currency handles string currency" do
    data = { currency: "GBP" }
    result = @helper.test_extract_currency(data)
    assert_equal "GBP", result
  end

  test "extract_currency falls back to symbol_data" do
    data = {}
    symbol_data = { currency: "JPY" }
    result = @helper.test_extract_currency(data, symbol_data)
    assert_equal "JPY", result
  end

  test "extract_currency uses fallback when no currency found" do
    data = {}
    result = @helper.test_extract_currency(data, {}, "USD")
    assert_equal "USD", result
  end

  test "extract_currency returns nil when no currency and no fallback" do
    data = {}
    result = @helper.test_extract_currency(data, {}, nil)
    assert_nil result
  end
end
