# frozen_string_literal: true

require "test_helper"

class BinanceAccount::UsdConverterTest < ActiveSupport::TestCase
  # A minimal host class that includes the concern so we can test it in isolation
  class Host
    include BinanceAccount::UsdConverter

    def initialize(family_currency)
      @family_currency = family_currency
    end

    def target_currency
      @family_currency
    end
  end

  test "returns original amount unchanged when target is USD" do
    host = Host.new("USD")
    amount, stale, rate_date = host.send(:convert_from_usd, 1000.0, date: Date.current)
    assert_equal 1000.0, amount
    assert_equal false, stale
    assert_nil rate_date
  end

  test "zero needs no exchange rate in any target currency" do
    ExchangeRate.expects(:find_or_fetch_rate).never
    host = Host.new("AED")

    [ 0, 0.0, 0.to_d ].each do |zero|
      amount, stale, rate_date = host.send(:convert_from_usd, zero, date: Date.current)
      assert_equal 0.to_d, amount
      assert_equal false, stale
      assert_nil rate_date
    end
  end

  test "returns converted amount when exact rate exists" do
    date = Date.new(2026, 3, 28)
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: date, rate: 0.92)

    host = Host.new("EUR")
    amount, stale, rate_date = host.send(:convert_from_usd, 1000.0, date: date)

    assert_in_delta 920.0, amount, 0.01
    assert_equal false, stale
    assert_nil rate_date
  end

  test "marks stale and returns converted amount when nearest rate used" do
    old_date = Date.new(2026, 3, 25)
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: old_date, rate: 0.91)

    host = Host.new("EUR")
    amount, stale, rate_date = host.send(:convert_from_usd, 1000.0, date: Date.new(2026, 3, 28))

    assert_in_delta 910.0, amount, 0.01
    assert_equal true, stale
    assert_equal old_date, rate_date
  end

  test "raises instead of relabeling raw USD when no rate is available" do
    host = Host.new("EUR")
    ExchangeRate.expects(:find_or_fetch_rate).returns(nil)

    error = assert_raises(Money::ConversionError) do
      host.send(:convert_from_usd, 1000.0, date: Date.new(2026, 3, 28))
    end
    assert_equal "USD", error.from_currency
    assert_equal "EUR", error.to_currency
    assert_equal Date.new(2026, 3, 28), error.date
  end

  test "build_stale_extra returns correct hash when stale" do
    host = Host.new("EUR")
    result = host.send(:build_stale_extra, true, Date.new(2026, 3, 25), Date.new(2026, 3, 28))

    assert_equal({ "binance" => { "stale_rate" => true, "rate_date_used" => "2026-03-25", "rate_target_date" => "2026-03-28" } }, result)
  end

  test "build_stale_extra returns cleared hash when not stale" do
    host = Host.new("EUR")
    result = host.send(:build_stale_extra, false, nil, Date.new(2026, 3, 28))

    assert_equal({ "binance" => { "stale_rate" => false } }, result)
  end
end
