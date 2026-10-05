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

  # Outside the 5-day lookback and with nothing from the provider, the last
  # stored rate is still a better answer than 1.
  test "rates_for falls back to the latest stored rate however old" do
    ExchangeRate.create!(from_currency: "JPY", to_currency: "USD", date: 90.days.ago.to_date, rate: 0.0067)
    @provider.expects(:fetch_exchange_rate).returns(provider_error_response(StandardError.new("no rate")))

    assert_equal 0.0067, ExchangeRate.rates_for(%w[JPY], to: "USD", date: Date.current)["JPY"].to_f
  end

  # A date before the pair's first stored rate takes that first rate, as the
  # balance chart already does.
  test "rates_for falls back to the earliest later rate when there is none before" do
    ExchangeRate.create!(from_currency: "JPY", to_currency: "USD", date: 10.days.ago.to_date, rate: 0.0068)
    ExchangeRate.create!(from_currency: "JPY", to_currency: "USD", date: 5.days.ago.to_date, rate: 0.0069)
    @provider.expects(:fetch_exchange_rate).returns(provider_error_response(StandardError.new("no rate")))

    assert_equal 0.0068, ExchangeRate.rates_for(%w[JPY], to: "USD", date: 30.days.ago.to_date)["JPY"].to_f
  end

  test "rate_sql is 1 for the same currency, the latest earlier rate, else the earliest later, else NULL" do
    ExchangeRate.create!(from_currency: "JPY", to_currency: "USD", date: 10.days.ago.to_date, rate: 0.0068)
    ExchangeRate.create!(from_currency: "JPY", to_currency: "USD", date: 5.days.ago.to_date, rate: 0.0069)

    rate_on = ->(from, on) {
      sql = ExchangeRate.rate_sql(from: ":from", to: ":to", on: "CAST(:on AS date)")
      ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT #{sql}", { from: from, to: "USD", on: on } ])
      )&.to_d
    }

    assert_equal 1, rate_on.call("USD", Date.current)
    assert_equal BigDecimal("0.0069"), rate_on.call("JPY", Date.current)
    assert_equal BigDecimal("0.0068"), rate_on.call("JPY", 7.days.ago.to_date)
    assert_equal BigDecimal("0.0068"), rate_on.call("JPY", 30.days.ago.to_date)
    assert_nil rate_on.call("KRW", Date.current)
  end

  test "currencies_without_rate names the currencies with no stored rate on any date" do
    ExchangeRate.create!(from_currency: "JPY", to_currency: "USD", date: 400.days.ago.to_date, rate: 0.009)

    assert_equal %w[KRW], ExchangeRate.currencies_without_rate(%w[USD JPY KRW KRW] + [ nil ], to: "USD")
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
