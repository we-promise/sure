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

  test "raises UnknownCurrencyError for unknown iso codes by default" do
    assert_raises(Money::Currency::UnknownCurrencyError) do
      Money::Currency.new(:xyz_not_a_currency)
    end
  end

  test "returns a generic placeholder when fallback is enabled" do
    currency = Money::Currency.new(:xyz_not_a_currency, fallback: true)

    assert_equal "XYZ_NOT_A_CURRENCY", currency.iso_code
    assert_equal 100, currency.minor_unit_conversion
    assert_equal 2, currency.default_precision
  end

  test "Money.new with fallback_currency: true accepts unknown currency" do
    money = Money.new(1, "ETH-Z", fallback_currency: true)

    assert_equal "ETH-Z", money.currency.iso_code
    assert_equal 1, money.amount
  end
end
