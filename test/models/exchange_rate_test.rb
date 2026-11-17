require "test_helper"
require "ostruct"

class ExchangeRateTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @provider = mock

    ExchangeRate.stubs(:provider).returns(@provider)
  end

  test "falls back to Frankfurter when the configured provider has no API key" do
    ExchangeRate.unstub(:provider)
    Setting.stubs(:exchange_rate_provider).returns("twelve_data")
    Setting.stubs(:twelve_data_api_key).returns(nil)

    with_env_overrides("EXCHANGE_RATE_PROVIDER" => nil, "TWELVE_DATA_API_KEY" => nil) do
      assert_instance_of Provider::Frankfurter, ExchangeRate.provider
      assert_equal "frankfurter", ExchangeRate.provider_name
    end
  end

  test "uses the configured provider when it has an API key" do
    ExchangeRate.unstub(:provider)
    Setting.stubs(:exchange_rate_provider).returns("twelve_data")

    with_env_overrides("EXCHANGE_RATE_PROVIDER" => nil, "TWELVE_DATA_API_KEY" => "test-key") do
      assert_instance_of Provider::TwelveData, ExchangeRate.provider
      assert_equal "twelve_data", ExchangeRate.provider_name
    end
  end

  test "keyless fallback on a signed-in request tries Frankfurter once, then skips it for a minute" do
    keyless_fallback(signed_in: true) do
      stub_request(:get, %r{/rate/SEK/JPY}).to_timeout
      10.times { assert_raises(Money::ConversionError) { Money.new(100, "SEK").exchange_to("JPY") } }
      5.times { |i| assert_equal({}, ExchangeRate.rates_for(%w[SEK], to: "JPY", date: Date.current - (i * 10).days)) }
      assert_requested :get, %r{/rate/SEK/JPY}, times: 1

      travel 61.seconds
      assert_nil ExchangeRate.find_or_fetch_rate(from: "SEK", to: "JPY", date: Date.current)
      assert_requested :get, %r{/rate/SEK/JPY}, times: 2
    end
  end

  test "keyless fallback keeps checking other pairs after an unsupported one" do
    keyless_fallback(signed_in: true) do
      stub_request(:get, %r{/rate/XAG/JPY}).to_return(status: 404, body: { message: "not found" }.to_json)
      stub_request(:get, %r{/rate/SEK/JPY}).to_return(status: 200, body: { date: Date.current.to_s, base: "SEK", quote: "JPY", rate: 14.2 }.to_json)

      assert_nil ExchangeRate.find_or_fetch_rate(from: "XAG", to: "JPY", date: Date.current)
      assert_equal 14.2, ExchangeRate.find_or_fetch_rate(from: "SEK", to: "JPY", date: Date.current).rate
    end
  end

  test "keyless fallback keeps checking other pairs after an invalid rate for one" do
    keyless_fallback(signed_in: true) do
      stub_request(:get, %r{/rate/SEK/JPY}).to_return(status: 200, body: { date: Date.current.to_s, base: "SEK", quote: "JPY", rate: 0 }.to_json)
      stub_request(:get, %r{/rate/DKK/JPY}).to_return(status: 200, body: { date: Date.current.to_s, base: "DKK", quote: "JPY", rate: nil }.to_json)
      stub_request(:get, %r{/rate/NOK/JPY}).to_return(status: 200, body: { date: Date.current.to_s, base: "NOK", quote: "JPY", rate: 13.9 }.to_json)

      assert_nil ExchangeRate.find_or_fetch_rate(from: "SEK", to: "JPY", date: Date.current)
      assert_nil ExchangeRate.find_or_fetch_rate(from: "DKK", to: "JPY", date: Date.current)
      assert_equal 13.9, ExchangeRate.find_or_fetch_rate(from: "NOK", to: "JPY", date: Date.current).rate
    end
  end

  test "keyless fallback skips Frankfurter for a minute after a refused connection" do
    keyless_fallback(signed_in: true) do
      stub_request(:get, %r{/rate/SEK/JPY}).to_raise(Faraday::ConnectionFailed.new("connection refused"))
      stub_request(:get, %r{/rate/NOK/JPY}).to_return(status: 200, body: { date: Date.current.to_s, base: "NOK", quote: "JPY", rate: 13.9 }.to_json)

      assert_nil ExchangeRate.find_or_fetch_rate(from: "SEK", to: "JPY", date: Date.current)
      assert_nil ExchangeRate.find_or_fetch_rate(from: "NOK", to: "JPY", date: Date.current)
      assert_not_requested :get, %r{/rate/NOK/JPY}
    end
  end

  test "keyless fallback outside a request, as in a sync job, keeps the retries" do
    keyless_fallback(signed_in: false) do
      stub_request(:get, %r{/rate/SEK/JPY}).to_timeout
        .then.to_return(status: 200, body: { date: Date.current.to_s, base: "SEK", quote: "JPY", rate: 14.2 }.to_json)

      assert_equal 14.2, ExchangeRate.find_or_fetch_rate(from: "SEK", to: "JPY", date: Date.current).rate
    end
  end

  test "keyless fallback records a direct quote under Frankfurter, so later lookups keep it" do
    keyless_fallback(signed_in: false) do
      ExchangeRatePair.where(from_currency: "SEK", to_currency: "NOK").delete_all
      stub_request(:get, %r{/rate/SEK/NOK}).to_return(status: 200, body: { date: Date.current.to_s, base: "SEK", quote: "NOK", rate: 0.95 }.to_json)

      ExchangeRate.find_or_fetch_rate(from: "SEK", to: "NOK", date: Date.current)
      pair = ExchangeRatePair.for_pair(from: "SEK", to: "NOK")

      assert_equal "frankfurter", pair.provider_name
      assert pair.quoted_directly?
    end
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
    assert_not ExchangeRatePair.exists?(from_currency: "USD", to_currency: "EUR")
  end

  test "records that the provider answered a pair with neither side USD" do
    ExchangeRate.delete_all
    ExchangeRatePair.delete_all
    @provider.expects(:fetch_exchange_rate)
             .returns(provider_success_response(OpenStruct.new(from: "KZT", to: "RUB", date: Date.current, rate: 0.16)))

    ExchangeRate.find_or_fetch_rate(from: "KZT", to: "RUB", date: Date.current)

    assert ExchangeRatePair.find_by!(from_currency: "KZT", to_currency: "RUB").quoted_directly?
  end

  # A rate stored here can be one a balance had to do without, so it is
  # passed to the balance refresh. One already stored is not.
  test "a rate fetched and stored is passed to the balance refresh" do
    ExchangeRate.delete_all
    @provider.expects(:fetch_exchange_rate).returns(provider_success_response(
      OpenStruct.new(from: "USD", to: "EUR", date: Date.current, rate: 1.2)
    ))
    refreshed = nil
    ExchangeRateBalanceRefreshJob.expects(:perform_later).with { |rates| refreshed = rates }.once

    ExchangeRate.find_or_fetch_rate(from: "USD", to: "EUR", date: Date.current, cache: true)
    stored = ExchangeRate.find_by!(from_currency: "USD", to_currency: "EUR", date: Date.current)
    assert_equal [ { from: "USD", to: "EUR", date: Date.current, stored_at: stored.created_at } ], refreshed

    ExchangeRateBalanceRefreshJob.expects(:perform_later).never
    ExchangeRate.find_or_fetch_rate(from: "USD", to: "EUR", date: Date.current, cache: true)
  end

  # The rate is stored before the refresh is queued, so a queue that cannot
  # take the job must not cost the caller the rate it fetched; support sees
  # the balance it left unrepaired in the debug log.
  test "a refresh that cannot be queued still returns the fetched rate" do
    ExchangeRate.delete_all
    @provider.expects(:fetch_exchange_rate).returns(provider_success_response(
      OpenStruct.new(from: "USD", to: "EUR", date: Date.current, rate: 1.2)
    ))
    ExchangeRateBalanceRefreshJob.expects(:perform_later).raises(StandardError, "queue unavailable")

    rate = nil
    assert_difference -> { DebugLogEntry.where(category: "exchange_rates").count }, 1 do
      rate = ExchangeRate.find_or_fetch_rate(from: "USD", to: "EUR", date: Date.current, cache: true)
    end

    assert_equal 1.2, rate.rate
    assert ExchangeRate.exists?(from_currency: "USD", to_currency: "EUR", date: Date.current)
  end

  # Inside a transaction the job is queued when it commits (ApplicationJob
  # enqueue_after_transaction_commit), after the write has returned; a queue
  # that cannot take it then must not fail whoever committed.
  test "a refresh that cannot be queued when a transaction commits does not fail the commit" do
    ExchangeRate.delete_all
    @provider.expects(:fetch_exchange_rate).returns(provider_success_response(
      OpenStruct.new(from: "USD", to: "EUR", date: Date.current, rate: 1.2)
    ))
    ExchangeRateBalanceRefreshJob.queue_adapter.stubs(:enqueue).raises(StandardError, "queue unavailable")

    rate = nil
    assert_difference -> { DebugLogEntry.where(category: "exchange_rates").count }, 1 do
      ExchangeRate.transaction do
        rate = ExchangeRate.find_or_fetch_rate(from: "USD", to: "EUR", date: Date.current, cache: true)
      end
    end

    assert_equal 1.2, rate.rate
  end

  # perform_later turns an adapter's ActiveJob::EnqueueError into a false
  # return rather than raising it, so the dropped refresh is logged all the
  # same.
  test "a refresh the queue adapter rejects is logged" do
    ExchangeRate.delete_all
    @provider.expects(:fetch_exchange_rate).returns(provider_success_response(
      OpenStruct.new(from: "USD", to: "EUR", date: Date.current, rate: 1.2)
    ))
    ExchangeRateBalanceRefreshJob.queue_adapter.stubs(:enqueue).raises(ActiveJob::EnqueueError, "queue unavailable")

    rate = nil
    assert_difference -> { DebugLogEntry.where(category: "exchange_rates").count }, 1 do
      rate = ExchangeRate.find_or_fetch_rate(from: "USD", to: "EUR", date: Date.current, cache: true)
    end

    assert_equal 1.2, rate.rate
  end

  test "returns nil on provider error" do
    provider_response = provider_error_response(StandardError.new("Test error"))

    @provider.expects(:fetch_exchange_rate).returns(provider_response)

    assert_nil ExchangeRate.find_or_fetch_rate(from: "USD", to: "EUR", date: Date.current, cache: true)
  end

  test "caches the latest cross on its shared observation date" do
    ExchangeRate.delete_all
    date = Date.current
    common_date = date - 1
    window = { start_date: date - ExchangeRate::Provided::NEAREST_RATE_LOOKBACK_DAYS, end_date: date }

    @provider.expects(:fetch_exchange_rate).returns(provider_error_response(StandardError.new("no KZT/RUB")))
    @provider.expects(:fetch_exchange_rates).with(from: "KZT", to: "USD", **window)
             .returns(provider_success_response([
               OpenStruct.new(from: "KZT", to: "USD", date: common_date, rate: 0.002),
               OpenStruct.new(from: "KZT", to: "USD", date: date, rate: 0.0022)
             ]))
    @provider.expects(:fetch_exchange_rates).with(from: "USD", to: "RUB", **window)
             .returns(provider_success_response([ OpenStruct.new(from: "USD", to: "RUB", date: common_date, rate: 80) ]))

    assert_equal 0.16, ExchangeRate.find_or_fetch_rate(from: "KZT", to: "RUB", date: date).rate.to_f
    assert_equal [ [ common_date, BigDecimal("0.16") ] ], ExchangeRate.where(from_currency: "KZT", to_currency: "RUB").pluck(:date, :rate)
  end

  test "does not ask Yahoo for the USD legs when its single lookup failed on authentication" do
    ExchangeRate.delete_all
    yahoo = Provider::YahooFinance.new
    ExchangeRate.stubs(:provider).returns(yahoo)
    auth = Provider::YahooFinance::AuthenticationError.new("no crumb")
    yahoo.expects(:fetch_exchange_rates).once.returns(provider_error_response(auth))

    assert_nil ExchangeRate.find_or_fetch_rate(from: "KZT", to: "RUB", date: Date.current)
  end

  test "asks for the USD legs once for a pair the provider lacks in every form" do
    ExchangeRate.delete_all
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    @provider.expects(:fetch_exchange_rate).twice.returns(provider_error_response(StandardError.new("no KZT/RUB")))
    @provider.expects(:fetch_exchange_rates).once.returns(provider_error_response(StandardError.new("no KZT/USD")))

    2.times { assert_nil ExchangeRate.find_or_fetch_rate(from: "KZT", to: "RUB", date: Date.current) }
  end

  test "builds the provider once per lookup, so its throttle spaces the direct request and the legs" do
    ExchangeRate.delete_all
    ExchangeRate.unstub(:provider)
    ExchangeRate.expects(:provider).once.returns(@provider)
    @provider.expects(:fetch_exchange_rate).returns(provider_error_response(StandardError.new("no KZT/RUB")))
    @provider.expects(:fetch_exchange_rates).once.returns(provider_error_response(StandardError.new("no KZT/USD")))

    assert_nil ExchangeRate.find_or_fetch_rate(from: "KZT", to: "RUB", date: Date.current)
  end

  test "returns a derived rate without storing it when cache is false" do
    ExchangeRate.delete_all
    date = Date.current

    @provider.expects(:fetch_exchange_rate).returns(provider_error_response(StandardError.new("no KZT/RUB")))
    @provider.expects(:fetch_exchange_rates).with(from: "KZT", to: "USD", start_date: date - 5, end_date: date)
             .returns(provider_success_response([ OpenStruct.new(from: "KZT", to: "USD", date: date, rate: 0.002) ]))
    @provider.expects(:fetch_exchange_rates).with(from: "USD", to: "RUB", start_date: date - 5, end_date: date)
             .returns(provider_success_response([ OpenStruct.new(from: "USD", to: "RUB", date: date, rate: 80) ]))

    assert_no_difference "ExchangeRate.count" do
      assert_equal 0.16, ExchangeRate.find_or_fetch_rate(from: "KZT", to: "RUB", date: date, cache: false).rate.to_f
    end
  end

  test "does not derive and cache a pair the provider has quoted before when it fails" do
    ExchangeRate.delete_all
    ExchangeRatePair.record_direct_quote(from: "KZT", to: "RUB")

    @provider.expects(:fetch_exchange_rate).returns(provider_error_response(StandardError.new("timeout")))
    @provider.expects(:fetch_exchange_rates).never

    assert_nil ExchangeRate.find_or_fetch_rate(from: "KZT", to: "RUB", date: Date.current)
    assert_equal 0, ExchangeRate.count
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

  # The read-back after a lost insert race only answers with a usable row;
  # otherwise the provider's rate stands. The table rejects a 0 since #3790,
  # so the unusable row is built in memory rather than stored.
  test "find_or_fetch_rate returns the provider's rate when a racing writer saved an unusable one" do
    @provider.expects(:fetch_exchange_rate).returns(
      provider_success_response(OpenStruct.new(from: "JPY", to: "USD", date: Date.current, rate: 0.0067))
    )
    ExchangeRate.stubs(:find_or_create_by!).raises(ActiveRecord::RecordNotUnique)
    ExchangeRate.stubs(:find_by!).returns(ExchangeRate.new(from_currency: "JPY", to_currency: "USD", date: Date.current, rate: 0))

    assert_equal 0.0067, ExchangeRate.find_or_fetch_rate(from: "JPY", to: "USD").rate.to_f
  end

  # Replacing an unusable row is best-effort: a failed write leaves the
  # provider's rate as the answer, not the row it could not replace. Built in
  # memory, as above.
  test "find_or_fetch_rate returns the provider's rate when replacing an unusable row fails" do
    @provider.expects(:fetch_exchange_rate).returns(
      provider_success_response(OpenStruct.new(from: "JPY", to: "USD", date: Date.current, rate: 0.0067))
    )
    ExchangeRate.stubs(:find_or_create_by!).returns(ExchangeRate.new(from_currency: "JPY", to_currency: "USD", date: Date.current, rate: 0))
    ExchangeRate.any_instance.stubs(:update!).raises(ActiveRecord::RecordInvalid.new(ExchangeRate.new))

    assert_equal 0.0067, ExchangeRate.find_or_fetch_rate(from: "JPY", to: "USD").rate.to_f
  end

  # rate_sql and currencies_without_rate read only stored rows, so a provider
  # rate that never reached the table must not count in rates_for either, or a
  # Ruby total includes an amount the SQL totals and the notice leave out.
  # Once it is stored, it counts.
  test "rates_for leaves out a provider rate it could not store" do
    @provider.stubs(:fetch_exchange_rate).returns(
      provider_success_response(OpenStruct.new(from: "JPY", to: "USD", date: Date.current, rate: 0.0067))
    )
    ExchangeRate.stubs(:find_or_create_by!).returns(ExchangeRate.new(from_currency: "JPY", to_currency: "USD", date: Date.current, rate: 0))
    ExchangeRate.any_instance.stubs(:update!).raises(ActiveRecord::RecordInvalid.new(ExchangeRate.new))

    assert_equal({}, ExchangeRate.rates_for(%w[JPY], to: "USD"))
    assert_equal %w[JPY], ExchangeRate.currencies_without_rate(%w[JPY], to: "USD")

    ExchangeRate.unstub(:find_or_create_by!)
    ExchangeRate.any_instance.unstub(:update!)

    assert_equal({ "JPY" => 0.0067 }, ExchangeRate.rates_for(%w[JPY], to: "USD").transform_values(&:to_f))
    assert_empty ExchangeRate.currencies_without_rate(%w[JPY], to: "USD")
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

  test "rejects rates that cannot convert an amount" do
    [ 0, -1.2, Float::NAN, Float::INFINITY ].each do |value|
      rate = ExchangeRate.new(from_currency: "CHF", to_currency: "CNY", date: Date.current, rate: value)

      assert_not rate.valid?, "expected a rate of #{value.inspect} to be rejected"
      assert rate.errors.of_kind?(:rate, :greater_than)
    end
  end

  # The importer writes with upsert_all, which skips model validations.
  test "database rejects a zero rate written without validations" do
    assert_raises ActiveRecord::CheckViolation do
      ExchangeRate.upsert_all(
        [ { from_currency: "CHF", to_currency: "CNY", date: Date.current, rate: 0 } ],
        unique_by: %i[from_currency to_currency date]
      )
    end
  end

  # Infinity only exists for numeric on PostgreSQL 14+ and satisfies `rate > 0`,
  # so the constraint excludes it with a text comparison instead.
  test "database rejects an infinite rate written without validations" do
    assert_raises ActiveRecord::CheckViolation do
      ExchangeRate.upsert_all(
        [ { from_currency: "CHF", to_currency: "CNY", date: Date.current, rate: Float::INFINITY } ],
        unique_by: %i[from_currency to_currency date]
      )
    end
  end

  # Cache keys read the newest stored rate on every dashboard, report and
  # transactions render; that read must not scan the table every family shares.
  test "the newest stored rate is read from an index" do
    assert_index_lookup ExchangeRate.select("MAX(updated_at)"), "index_exchange_rates_on_updated_at"
  end

  test "the newest stored rate into a currency is read from an index" do
    assert_index_lookup ExchangeRate.where(to_currency: "USD").select("MAX(updated_at)"),
      "index_exchange_rates_on_to_currency_and_updated_at"
  end

  test "updated_at_version changes when a rate is stored within the same second as the previous one" do
    second = Time.zone.parse("2026-11-16 10:00:00")
    ExchangeRate.update_all(updated_at: second - 1.day)
    first = ExchangeRate.create!(from_currency: "KRW", to_currency: "USD", date: Date.current, rate: 0.00075)
    first.update_columns(updated_at: second + 0.1)
    before = ExchangeRate.updated_at_version

    later = ExchangeRate.create!(from_currency: "JPY", to_currency: "USD", date: Date.current, rate: 0.0065)
    later.update_columns(updated_at: second + 0.6)

    assert_not_equal before, ExchangeRate.updated_at_version
  end

  test "updated_at_version on a scope is that scope's newest update, read without counting rows" do
    eur = ExchangeRate.create!(from_currency: "KRW", to_currency: "EUR", date: Date.current, rate: 0.00065)
    eur.update_columns(updated_at: Time.zone.parse("2026-11-16 10:00:00.25"))
    ExchangeRate.create!(from_currency: "KRW", to_currency: "GBP", date: Date.current, rate: 0.00055)
    scope = ExchangeRate.where(to_currency: "EUR")

    version = nil
    assert_no_queries_match(/COUNT/i) do
      version = scope.updated_at_version
    end

    assert_equal scope.maximum(:updated_at).to_f, version
  end

  private
    def keyless_fallback(signed_in:, &block)
      ExchangeRate.unstub(:provider)
      ExchangeRate.where(from_currency: %w[SEK XAG NOK DKK], to_currency: "JPY").delete_all
      Setting.stubs(:exchange_rate_provider).returns("twelve_data")
      Setting.stubs(:twelve_data_api_key).returns(nil)
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      Current.session = sessions(:one) if signed_in
      with_env_overrides("EXCHANGE_RATE_PROVIDER" => nil, "TWELVE_DATA_API_KEY" => nil, &block)
    end

    # With sequential scans priced out, the planner uses an index whenever one
    # can answer the query; without one it still falls back to a sequential scan.
    def assert_index_lookup(relation, index_name)
      plan = ExchangeRate.transaction do
        ExchangeRate.connection.execute("SET LOCAL enable_seqscan = off")
        ExchangeRate.connection.select_values("EXPLAIN #{relation.to_sql}").join("\n")
      end
      assert_includes plan, index_name, "expected the query to use #{index_name}:\n#{plan}"
    end
end
