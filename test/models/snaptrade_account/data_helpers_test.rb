# frozen_string_literal: true

require "test_helper"

class SnaptradeAccount::DataHelpersTest < ActiveSupport::TestCase
  class TestHelper
    include SnaptradeAccount::DataHelpers

    public :parse_decimal, :parse_date, :resolve_security, :extract_currency,
           :extract_security_name, :extract_exchange, :extract_country_code
  end

  setup do
    @helper = TestHelper.new
  end

  # ==========================================================================
  # extract_security_name tests
  # ==========================================================================

  test "extract_security_name formats option contract with full details" do
    symbol_data = {
      option_type: "CALL",
      strike_price: 51.0,
      expiration_date: "2026-02-20",
      underlying_symbol: { symbol: "TQQQ" }
    }
    result = @helper.extract_security_name(symbol_data, "TQQQ  260220C00051000")
    assert_equal "TQQQ $51 CALL (2026-02-20)", result
  end

  test "extract_security_name formats option contract with fractional strike" do
    symbol_data = {
      option_type: "CALL",
      strike_price: 51.5,
      expiration_date: "2026-02-13",
      underlying_symbol: { symbol: "TQQQ" }
    }
    result = @helper.extract_security_name(symbol_data, "TQQQ  260213C00051500")
    assert_equal "TQQQ $51.5 CALL (2026-02-13)", result
  end

  test "extract_security_name formats ISO timestamp expiration as YYYY-MM-DD" do
    symbol_data = {
      option_type: "CALL",
      strike_price: 51.0,
      expiration_date: "2026-02-20T00:00:00Z",
      underlying_symbol: { symbol: "TQQQ" }
    }
    result = @helper.extract_security_name(symbol_data, "TQQQ  260220C00051000")
    assert_equal "TQQQ $51 CALL (2026-02-20)", result
  end

  test "extract_security_name titleizes all-caps company descriptions" do
    result = @helper.extract_security_name({ description: "APPLE INC" }, "AAPL")
    assert_equal "Apple Inc", result

    result = @helper.extract_security_name({ description: "MICROSOFT CORP" }, "MSFT")
    assert_equal "Microsoft Corp", result
  end

  test "extract_security_name preserves ticker without titleize when description is blank" do
    # Ticker longer than 4 chars should NOT be titleized to 'Googl' or 'Btcusd'
    result = @helper.extract_security_name({}, "GOOGL")
    assert_equal "GOOGL", result

    result = @helper.extract_security_name({ description: "" }, "BTCUSD")
    assert_equal "BTCUSD", result
  end

  test "extract_security_name preserves ticker without titleize when description is generic type" do
    assert_equal "IBM", @helper.extract_security_name({ description: "COMMON STOCK" }, "IBM")
    assert_equal "GOOGL", @helper.extract_security_name({ description: "Common Stock" }, "GOOGL")
    assert_equal "BTCUSD", @helper.extract_security_name({ description: "CRYPTOCURRENCY" }, "BTCUSD")
    assert_equal "SPY", @helper.extract_security_name({ description: "ETF" }, "SPY")
    assert_equal "VFIAX", @helper.extract_security_name({ description: "MUTUAL FUND" }, "VFIAX")
  end

  test "extract_security_name preserves raw OCC option ticker without titleize" do
    result = @helper.extract_security_name({}, "TQQQ  260220C00051000")
    assert_equal "TQQQ  260220C00051000", result
  end

  # ==========================================================================
  # extract_exchange tests
  # ==========================================================================

  test "extract_exchange returns string exchange directly" do
    assert_equal "NASDAQ", @helper.extract_exchange({ exchange: "NASDAQ" })
  end

  test "extract_exchange returns mic_code from hash exchange" do
    assert_equal "XNAS", @helper.extract_exchange({ exchange: { mic_code: "XNAS" } })
  end

  test "extract_exchange falls back to underlying_symbol exchange" do
    symbol_data = {
      underlying_symbol: {
        exchange: { mic_code: "XNYS" }
      }
    }
    assert_equal "XNYS", @helper.extract_exchange(symbol_data)
  end

  # ==========================================================================
  # extract_country_code tests
  # ==========================================================================

  test "extract_country_code derives country from currency code" do
    assert_equal "US", @helper.extract_country_code({ currency: "USD" })
    assert_equal "CA", @helper.extract_country_code({ currency: "CAD" })
    assert_equal "GB", @helper.extract_country_code({ currency: "GBP" })
  end

  test "extract_country_code falls back to underlying_symbol currency" do
    symbol_data = {
      underlying_symbol: {
        currency: { code: "USD" }
      }
    }
    assert_equal "US", @helper.extract_country_code(symbol_data)
  end

  test "extract_security_name formats option contract when underlying_symbol is a bare string" do
    symbol_data = {
      option_type: "CALL",
      strike_price: 51.0,
      expiration_date: "2026-02-20",
      underlying_symbol: "TQQQ"
    }
    result = @helper.extract_security_name(symbol_data, "TQQQ  260220C00051000")
    assert_equal "TQQQ $51 CALL (2026-02-20)", result
  end

  test "extract_security_name handles malformed non-hash non-string underlying_symbol gracefully" do
    symbol_data = {
      option_type: "CALL",
      strike_price: 51.0,
      expiration_date: "2026-02-20",
      underlying_symbol: 12345
    }
    result = @helper.extract_security_name(symbol_data, "TQQQ  260220C00051000")
    assert_equal "TQQQ  260220C00051000", result
  end

  test "extract_exchange handles bare string and malformed underlying_symbol without error" do
    assert_nil @helper.extract_exchange({ underlying_symbol: "TQQQ" })
    assert_nil @helper.extract_exchange({ underlying_symbol: [ "invalid" ] })
    assert_nil @helper.extract_exchange({ underlying_symbol: 123 })
  end

  test "extract_country_code handles bare string and malformed underlying_symbol without error" do
    assert_nil @helper.extract_country_code({ underlying_symbol: "TQQQ" })
    assert_nil @helper.extract_country_code({ underlying_symbol: [ "invalid" ] })
    assert_nil @helper.extract_country_code({ underlying_symbol: 123 })
  end
end
