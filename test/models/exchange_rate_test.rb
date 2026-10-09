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

  # Older than the lookback rates_for treats as current: today's figures use
  # a rate from some other day. Within it (a weekend, a holiday) is current.
  test "stale_rate_dates names currencies whose newest rate is older than the lookback" do
    ExchangeRate.create!(from_currency: "JPY", to_currency: "USD", date: 30.days.ago.to_date, rate: 0.0067)
    ExchangeRate.create!(from_currency: "CAD", to_currency: "USD", date: ExchangeRate::NEAREST_RATE_LOOKBACK_DAYS.days.ago.to_date, rate: 0.73)
    ExchangeRate.create!(from_currency: "CAD", to_currency: "USD", date: 40.days.ago.to_date, rate: 0.71)

    stale = ExchangeRate.stale_rate_dates(%w[USD JPY CAD KRW], to: "USD")

    assert_equal({ "JPY" => 30.days.ago.to_date }, stale, "CAD is current, KRW has no rate at all, USD needs none")
  end

  # Today converts at the latest rate on or before today, so a future-dated row
  # must not hide that the rate in use is old. A currency with only future rows
  # has no older rate to name and stays out, as before.
  test "stale_rate_dates ignores rates dated after as_of" do
    ExchangeRate.create!(from_currency: "JPY", to_currency: "USD", date: 30.days.ago.to_date, rate: 0.0067)
    ExchangeRate.create!(from_currency: "JPY", to_currency: "USD", date: 3.days.from_now.to_date, rate: 0.0068)
    ExchangeRate.create!(from_currency: "CHF", to_currency: "USD", date: 3.days.from_now.to_date, rate: 1.1)

    sql = ExchangeRate.rate_sql(from: "'JPY'", to: "'USD'", on: "CURRENT_DATE")
    assert_equal BigDecimal("0.0067"), ActiveRecord::Base.connection.select_value("SELECT #{sql}").to_d

    assert_equal({ "JPY" => 30.days.ago.to_date }, ExchangeRate.stale_rate_dates(%w[JPY CHF], to: "USD"))
  end

  # A stored 0 or negative is no rate: multiplying by it books an amount as
  # nothing or flips its sign. The usable rate behind it is used instead.
  test "rates_for and rate_sql skip a stored rate of zero or below" do
    ExchangeRate.create!(from_currency: "JPY", to_currency: "USD", date: 3.days.ago.to_date, rate: 0.0067)
    ExchangeRate.create!(from_currency: "JPY", to_currency: "USD", date: 1.day.ago.to_date, rate: -1)
    ExchangeRate.create!(from_currency: "JPY", to_currency: "USD", date: Date.current, rate: 0)
    ExchangeRate.create!(from_currency: "KRW", to_currency: "USD", date: Date.current, rate: 0)
    @provider.stubs(:fetch_exchange_rate).returns(provider_error_response(StandardError.new("no rate")))

    assert_equal({ "JPY" => 0.0067 }, ExchangeRate.rates_for(%w[JPY KRW], to: "USD").transform_values(&:to_f))

    sql = ExchangeRate.rate_sql(from: ":from", to: "'USD'", on: "CURRENT_DATE")
    rate = ->(from) { ActiveRecord::Base.connection.select_value(ActiveRecord::Base.sanitize_sql_array([ "SELECT #{sql}", { from: from } ]))&.to_d }
    assert_equal BigDecimal("0.0067"), rate.call("JPY")
    assert_nil rate.call("KRW")
    assert_equal %w[KRW], ExchangeRate.currencies_without_rate(%w[JPY KRW], to: "USD")
  end

  # A stored 0 on the day, or within the lookback, used to be returned as
  # found, so the provider was never asked and the currency fell out of totals
  # though a usable rate was one call away. The provider's answer also replaces
  # the unusable row.
  test "find_or_fetch_rate asks the provider past a stored rate of zero or below, and repairs it" do
    ExchangeRate.create!(from_currency: "JPY", to_currency: "USD", date: Date.current, rate: 0)
    ExchangeRate.create!(from_currency: "JPY", to_currency: "USD", date: 2.days.ago.to_date, rate: -1)
    @provider.expects(:fetch_exchange_rate).once.returns(
      provider_success_response(OpenStruct.new(from: "JPY", to: "USD", date: Date.current, rate: 0.0067))
    )

    assert_equal 0.0067, ExchangeRate.rates_for(%w[JPY], to: "USD")["JPY"].to_f
    assert_equal BigDecimal("0.0067"), ExchangeRate.find_by(from_currency: "JPY", to_currency: "USD", date: Date.current).rate
  end

  # Another process can save a 0 for the same pair and date between the lookup
  # and the insert. Read back, that row is no answer; the provider's is.
  test "find_or_fetch_rate returns the provider's rate when a racing writer saved an unusable one" do
    ExchangeRate.create!(from_currency: "JPY", to_currency: "USD", date: Date.current, rate: 0)
    @provider.expects(:fetch_exchange_rate).returns(
      provider_success_response(OpenStruct.new(from: "JPY", to: "USD", date: Date.current, rate: 0.0067))
    )
    ExchangeRate.stubs(:find_or_create_by!).raises(ActiveRecord::RecordNotUnique)

    assert_equal 0.0067, ExchangeRate.find_or_fetch_rate(from: "JPY", to: "USD").rate.to_f
  end

  # Replacing the unusable row is best-effort: a failed write leaves the
  # provider's rate as the answer, not the row it could not replace.
  test "find_or_fetch_rate returns the provider's rate when replacing an unusable row fails" do
    ExchangeRate.create!(from_currency: "JPY", to_currency: "USD", date: Date.current, rate: 0)
    @provider.expects(:fetch_exchange_rate).returns(
      provider_success_response(OpenStruct.new(from: "JPY", to: "USD", date: Date.current, rate: 0.0067))
    )
    ExchangeRate.any_instance.stubs(:update!).raises(ActiveRecord::RecordInvalid.new(ExchangeRate.new))

    assert_equal 0.0067, ExchangeRate.find_or_fetch_rate(from: "JPY", to: "USD").rate.to_f
  end

  test "rates_for converts the target currency itself at 1" do
    @provider.expects(:fetch_exchange_rate).never

    assert_equal({ "USD" => 1 }, ExchangeRate.rates_for(%w[USD], to: "USD"))
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
