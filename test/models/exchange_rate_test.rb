require "test_helper"
require "ostruct"

class ExchangeRateTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @provider = mock

    ExchangeRate.stubs(:provider).returns(@provider)
  end

  test "finds rate in DB" do
    existing_rate = exchange_rates(:one)

    @provider.expects(:fetch_exchange_rate).never

    assert_equal existing_rate, ExchangeRate.find_or_fetch_rate(
                                              from: existing_rate.from_currency,
                                              to: existing_rate.to_currency,
                                              date: existing_rate.date
                                            )
  end

  test "fetches rate from provider without cache" do
    ExchangeRate.delete_all

    provider_response = provider_success_response(
      OpenStruct.new(
        from: "USD",
        to: "EUR",
        date: Date.current,
        rate: 1.2
      )
    )

    @provider.expects(:fetch_exchange_rate).returns(provider_response)

    assert_no_difference "ExchangeRate.count" do
      assert_equal 1.2, ExchangeRate.find_or_fetch_rate(from: "USD", to: "EUR", date: Date.current, cache: false).rate
    end
  end

  test "fetches rate from provider with cache" do
    ExchangeRate.delete_all

    provider_response = provider_success_response(
      OpenStruct.new(
        from: "USD",
        to: "EUR",
        date: Date.current,
        rate: 1.2
      )
    )

    @provider.expects(:fetch_exchange_rate).returns(provider_response)

    assert_difference "ExchangeRate.count", 1 do
      assert_equal 1.2, ExchangeRate.find_or_fetch_rate(from: "USD", to: "EUR", date: Date.current, cache: true).rate
    end
  end

  test "returns nil on provider error" do
    provider_response = provider_error_response(StandardError.new("Test error"))

    @provider.expects(:fetch_exchange_rate).returns(provider_response)

    assert_nil ExchangeRate.find_or_fetch_rate(from: "USD", to: "EUR", date: Date.current, cache: true)
  end

  test "reuses nearest cached rate within lookback window instead of calling provider" do
    # Simulate a rate saved under Friday's date when Saturday is requested
    friday = 1.day.ago.to_date
    ExchangeRate.create!(from_currency: "USD", to_currency: "JPY", date: friday, rate: 150.5)

    saturday = Date.current

    @provider.expects(:fetch_exchange_rate).never

    result = ExchangeRate.find_or_fetch_rate(from: "USD", to: "JPY", date: saturday)
    assert_equal 150.5, result.rate
    assert_equal friday, result.date
  end

  # A pair with no rate anywhere -- not stored, not within the lookback, not
  # from the provider -- is left out. It used to come back as 1, which every
  # caller read as parity: a ¥1,000,000 gain reported as $1,000,000 (#3640).
  test "rates_for leaves out a currency it has no rate for, rather than returning 1" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.current, rate: 1.08)
    ExchangeRate.where(from_currency: "JPY", to_currency: "USD").delete_all

    @provider.expects(:fetch_exchange_rate)
             .with(from: "JPY", to: "USD", date: Date.current)
             .returns(provider_error_response(StandardError.new("no rate")))

    rates = ExchangeRate.rates_for(%w[EUR JPY], to: "USD", date: Date.current)

    assert_equal({ "EUR" => 1.08 }, rates.transform_values(&:to_f))
    assert_not rates.key?("JPY")
  end

  test "does not reuse cached rate outside lookback window" do
    old_date = (ExchangeRate::NEAREST_RATE_LOOKBACK_DAYS + 1).days.ago.to_date
    ExchangeRate.create!(from_currency: "USD", to_currency: "JPY", date: old_date, rate: 140.0)

    provider_response = provider_success_response(
      OpenStruct.new(from: "USD", to: "JPY", date: Date.current, rate: 155.0)
    )

    @provider.expects(:fetch_exchange_rate).returns(provider_response)

    result = ExchangeRate.find_or_fetch_rate(from: "USD", to: "JPY", date: Date.current)
    assert_equal 155.0, result.rate
  end
end
