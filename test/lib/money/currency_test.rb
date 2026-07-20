require "test_helper"

class Money::CurrencyTest < ActiveSupport::TestCase
  setup do
    @currency = Money::Currency.new(:usd)
  end

  test "has many currencies" do
    assert_operator Money::Currency.all.count, :>, 100
  end

  test "can test equality of currencies" do
    assert_equal Money::Currency.new(:usd), Money::Currency.new(:usd)
    assert_not_equal Money::Currency.new(:usd), Money::Currency.new(:eur)
  end

  test "can get metadata about a currency" do
    assert_equal "USD", @currency.iso_code
    assert_equal "United States Dollar", @currency.name
    assert_equal "$", @currency.symbol
    assert_equal 1, @currency.priority
    assert_equal "Cent", @currency.minor_unit
    assert_equal 100, @currency.minor_unit_conversion
    assert_equal 1, @currency.smallest_denomination
    assert_equal ".", @currency.separator
    assert_equal ",", @currency.delimiter
    assert_equal "%u%n", @currency.default_format
    assert_equal 2, @currency.default_precision
  end

  test "step returns the smallest value of the currency" do
    assert_equal 0.01, @currency.step
  end

  test "includes ethereum metadata" do
    currency = Money::Currency.new(:eth)

    assert_equal "ETH", currency.iso_code
    assert_equal "Ethereum", currency.name
    assert_equal "Ξ", currency.symbol
    assert_equal "Wei", currency.minor_unit
    assert_equal 1000000000000000000, currency.minor_unit_conversion
    assert_equal 8, currency.default_precision
    assert_equal 0.00000001, currency.step
  end
end
