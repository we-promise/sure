require "test_helper"

class Trading212DataHelpersTest < ActiveSupport::TestCase
  # Test class that includes the DataHelpers concern and exposes private methods
  class TestHelper
    include Trading212Account::DataHelpers

    attr_accessor :currency, :instruments_map

    def initialize(currency: "USD", instruments_map: {})
      @currency = currency
      @instruments_map = instruments_map
    end

    def test_parse_decimal(value)     = parse_decimal(value)
    def test_parse_date(value)        = parse_date(value)
    def test_standard_ticker(v)       = standard_ticker(v)
    def test_resolve_security_for_ticker(v) = resolve_security_for_ticker(v)
    def test_resolve_security_direct(isin, ticker, name) = resolve_security_direct(isin, ticker, name)
    def test_instrument_currency(v)    = instrument_currency(v)
  end

  setup do
    @helper = TestHelper.new
  end

  # === parse_decimal ===

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

  test "parse_decimal handles negative values" do
    result = @helper.test_parse_decimal("-50.25")
    assert_equal BigDecimal("-50.25"), result
  end

  test "parse_decimal strips whitespace" do
    result = @helper.test_parse_decimal("  42.0  ")
    assert_equal BigDecimal("42.0"), result
  end

  test "parse_decimal returns nil for nil input" do
    assert_nil @helper.test_parse_decimal(nil)
  end

  test "parse_decimal returns nil for blank string" do
    assert_nil @helper.test_parse_decimal("")
  end

  test "parse_decimal returns nil for invalid string" do
    assert_nil @helper.test_parse_decimal("not_a_number")
  end

  # === parse_date ===

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
    assert_equal Date.new(2024, 6, 15), result
  end

  test "parse_date returns nil for nil input" do
    assert_nil @helper.test_parse_date(nil)
  end

  test "parse_date returns nil for blank input" do
    assert_nil @helper.test_parse_date("")
  end

  test "parse_date returns nil for invalid string" do
    assert_nil @helper.test_parse_date("invalid_date")
  end

  # === standard_ticker ===

  test "standard_ticker extracts first segment of T212 ticker" do
    assert_equal "AAPL", @helper.test_standard_ticker("AAPL_US_EQ")
  end

  test "standard_ticker handles single segment" do
    assert_equal "TSLA", @helper.test_standard_ticker("TSLA")
  end

  test "standard_ticker uppercases the ticker" do
    assert_equal "AAPL", @helper.test_standard_ticker("aapl_us_eq")
  end

  test "standard_ticker handles empty string" do
    assert_equal "", @helper.test_standard_ticker("")
  end

  # === resolve_security_for_ticker ===

  test "resolve_security_for_ticker finds via instruments_map" do
    Security.create!(ticker: "AAPL", name: "Apple Inc.")
    helper = TestHelper.new(
      instruments_map: {
        "AAPL_US_EQ" => { "shortName" => "Apple Inc.", "currencyCode" => "USD" }
      }
    )

    security = helper.test_resolve_security_for_ticker("AAPL_US_EQ")
    assert_equal "AAPL", security.ticker
    assert_equal "Apple Inc.", security.name
  end

  test "resolve_security_for_ticker creates security if not found" do
    helper = TestHelper.new(instruments_map: {})

    security = helper.test_resolve_security_for_ticker("MSFT_US_EQ")
    assert_equal "MSFT", security.ticker
  end

  test "resolve_security_for_ticker handles nil input" do
    security = @helper.test_resolve_security_for_ticker(nil)
    assert_not_nil security
    assert_equal "", security.ticker
  end

  # === resolve_security_direct ===

  test "resolve_security_direct finds existing by ticker" do
    existing = Security.create!(ticker: "GOOGL", name: "Alphabet Inc.")

    result = @helper.test_resolve_security_direct("ISIN123", "GOOGL", "Alphabet Inc.")
    assert_equal existing, result
  end

  test "resolve_security_direct creates new when not found" do
    result = @helper.test_resolve_security_direct("ISIN456", "NVDA", "Nvidia Corp")
    assert_equal "NVDA", result.ticker
    assert_equal "Nvidia Corp", result.name
  end

  test "resolve_security_direct handles race condition on create" do
    Security.create!(ticker: "RACE", name: "Already Exists")

    result = @helper.test_resolve_security_direct(nil, "RACE", "New Name")
    assert_equal "RACE", result.ticker
    assert_equal "Already Exists", result.name
  end

  # === instrument_currency ===

  test "instrument_currency returns currency from instruments_map" do
    helper = TestHelper.new(
      currency: "USD",
      instruments_map: { "AAPL_US_EQ" => { "currencyCode" => "EUR" } }
    )

    assert_equal "EUR", helper.test_instrument_currency("AAPL_US_EQ")
  end

  test "instrument_currency falls back to account currency" do
    helper = TestHelper.new(
      currency: "USD",
      instruments_map: {}
    )

    assert_equal "USD", helper.test_instrument_currency("UNKNOWN_TICKER")
  end

  test "instrument_currency falls back when instrument has no currencyCode" do
    helper = TestHelper.new(
      currency: "GBP",
      instruments_map: { "TSLA_US_EQ" => { "shortName" => "Tesla" } }
    )

    assert_equal "GBP", helper.test_instrument_currency("TSLA_US_EQ")
  end
end
