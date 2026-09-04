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

  test "ethereum uses wei native scale" do
    eth = Money::Currency.new(:eth)
    assert_equal "Ethereum", eth.name
    assert_equal "ETH", eth.iso_code
    assert_equal "Ξ", eth.symbol
    assert_equal "Wei", eth.minor_unit
    assert_equal 1000000000000000000, eth.minor_unit_conversion
    assert_equal 8, eth.default_precision
  end

  test "ethereum step represents display precision" do
    eth = Money::Currency.new(:eth)
    assert_equal 0.00000001, eth.step
  end

  test "ethereum conversion formula: step = 10^-default_precision" do
    eth = Money::Currency.new(:eth)
    expected_step = 1.0 / (10 ** eth.default_precision)
    assert_equal expected_step, eth.step
  end
end
