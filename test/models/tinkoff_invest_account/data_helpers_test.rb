require "test_helper"

class TinkoffInvestAccount::DataHelpersTest < ActiveSupport::TestCase
  class HelperHost
    include TinkoffInvestAccount::DataHelpers

    def parse_decimal_val(val)
      parse_decimal(val)
    end

    def parse_quotation_val(val)
      parse_quotation(val)
    end

    def parse_money_val(val, fallback = "RUB")
      parse_money(val, fallback)
    end

    def parse_date_val(val)
      parse_date(val)
    end
  end

  setup do
    @host = HelperHost.new
  end

  test "parses decimals, quotations, money values, and dates safely" do
    assert_equal BigDecimal("123.45"), @host.parse_decimal_val(" 123.45 ")
    assert_nil @host.parse_decimal_val("invalid")

    assert_equal BigDecimal("240.5"), @host.parse_quotation_val("units" => "240", "nano" => 500_000_000)
    assert_equal [ BigDecimal("18.5"), "RUB" ], @host.parse_money_val("currency" => "rub", "units" => "18", "nano" => 500_000_000)
    assert_equal Date.new(2025, 4, 1), @host.parse_date_val("2025-04-01T14:30:00Z")
  end
end
