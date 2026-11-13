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
      5.times { |i| assert_equal({ "SEK" => 1 }, ExchangeRate.rates_for(%w[SEK], to: "JPY", date: Date.current - (i * 10).days)) }
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

  test "keyless fallback outside a request, as in a sync job, keeps the retries" do
    keyless_fallback(signed_in: false) do
      stub_request(:get, %r{/rate/SEK/JPY}).to_timeout
        .then.to_return(status: 200, body: { date: Date.current.to_s, base: "SEK", quote: "JPY", rate: 14.2 }.to_json)

      assert_equal 14.2, ExchangeRate.find_or_fetch_rate(from: "SEK", to: "JPY", date: Date.current).rate
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

  private
    def keyless_fallback(signed_in:, &block)
      ExchangeRate.unstub(:provider)
      ExchangeRate.where(from_currency: %w[SEK XAG], to_currency: "JPY").delete_all
      Setting.stubs(:exchange_rate_provider).returns("twelve_data")
      Setting.stubs(:twelve_data_api_key).returns(nil)
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      Current.session = sessions(:one) if signed_in
      with_env_overrides("EXCHANGE_RATE_PROVIDER" => nil, "TWELVE_DATA_API_KEY" => nil, &block)
    end
end
