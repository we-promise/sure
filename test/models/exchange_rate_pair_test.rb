require "test_helper"

class ExchangeRatePairTest < ActiveSupport::TestCase
  test "for_pair creates a new pair if none exists" do
    ExchangeRatePair.delete_all
    pair = ExchangeRatePair.for_pair(from: "USD", to: "EUR")

    assert_equal "USD", pair.from_currency
    assert_equal "EUR", pair.to_currency
    assert_nil pair.first_provider_rate_on
  end

  test "for_pair returns existing pair idempotently" do
    ExchangeRatePair.delete_all
    pair1 = ExchangeRatePair.for_pair(from: "USD", to: "EUR")
    pair2 = ExchangeRatePair.for_pair(from: "USD", to: "EUR")

    assert_equal pair1.id, pair2.id
  end

  test "for_pair auto-resets clamp when provider changes" do
    ExchangeRatePair.delete_all

    original_provider = Setting.exchange_rate_provider
    begin
      Setting.exchange_rate_provider = "twelve_data"
      ExchangeRatePair.create!(
        from_currency: "USD",
        to_currency: "EUR",
        first_provider_rate_on: 1.year.ago.to_date,
        provider_name: "twelve_data"
      )

      refreshed = ExchangeRatePair.for_pair(from: "USD", to: "EUR", provider_name: "yahoo_finance")

      assert_nil refreshed.first_provider_rate_on
      assert_equal "yahoo_finance", refreshed.provider_name
    ensure
      Setting.exchange_rate_provider = original_provider
    end
  end

  test "for_pair resets clamp when the Twelve Data key is removed and Frankfurter takes over" do
    ExchangeRatePair.delete_all
    ExchangeRatePair.create!(
      from_currency: "USD", to_currency: "EUR",
      first_provider_rate_on: 1.year.ago.to_date, provider_name: "twelve_data"
    )
    Setting.stubs(:exchange_rate_provider).returns("twelve_data")
    Setting.stubs(:twelve_data_api_key).returns(nil)

    with_env_overrides("EXCHANGE_RATE_PROVIDER" => nil, "TWELVE_DATA_API_KEY" => nil) do
      refreshed = ExchangeRatePair.for_pair(from: "USD", to: "EUR")

      assert_nil refreshed.first_provider_rate_on
      assert_equal "frankfurter", refreshed.provider_name
    end
  end

  test "for_pair resets clamp when a Twelve Data key is added" do
    ExchangeRatePair.delete_all
    ExchangeRatePair.create!(
      from_currency: "USD", to_currency: "EUR",
      first_provider_rate_on: 1.year.ago.to_date, provider_name: "frankfurter"
    )
    Setting.stubs(:exchange_rate_provider).returns("twelve_data")

    with_env_overrides("EXCHANGE_RATE_PROVIDER" => nil, "TWELVE_DATA_API_KEY" => "test-key") do
      refreshed = ExchangeRatePair.for_pair(from: "USD", to: "EUR")

      assert_nil refreshed.first_provider_rate_on
      assert_equal "twelve_data", refreshed.provider_name
    end
  end

  test "record_first_provider_rate_on sets date on NULL" do
    ExchangeRatePair.delete_all
    ExchangeRatePair.for_pair(from: "USD", to: "EUR")

    ExchangeRatePair.record_first_provider_rate_on(from: "USD", to: "EUR", date: 6.months.ago.to_date)

    pair = ExchangeRatePair.find_by!(from_currency: "USD", to_currency: "EUR")
    assert_equal 6.months.ago.to_date, pair.first_provider_rate_on
  end

  test "record_first_provider_rate_on moves earlier but not forward" do
    ExchangeRatePair.delete_all

    original_provider = Setting.exchange_rate_provider
    begin
      Setting.exchange_rate_provider = "twelve_data"
      ExchangeRatePair.create!(
        from_currency: "USD",
        to_currency: "EUR",
        first_provider_rate_on: 6.months.ago.to_date,
        provider_name: "twelve_data"
      )

      ExchangeRatePair.record_first_provider_rate_on(from: "USD", to: "EUR", date: 1.year.ago.to_date)
      pair = ExchangeRatePair.find_by!(from_currency: "USD", to_currency: "EUR")
      assert_equal 1.year.ago.to_date, pair.first_provider_rate_on

      ExchangeRatePair.record_first_provider_rate_on(from: "USD", to: "EUR", date: 3.months.ago.to_date)
      pair.reload
      assert_equal 1.year.ago.to_date, pair.first_provider_rate_on
    ensure
      Setting.exchange_rate_provider = original_provider
    end
  end
end
