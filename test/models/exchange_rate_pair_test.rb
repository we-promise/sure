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

    Setting.exchange_rate_provider = "twelve_data"
    pair = ExchangeRatePair.create!(
      from_currency: "USD",
      to_currency: "EUR",
      first_provider_rate_on: 1.year.ago.to_date,
      provider_name: "twelve_data"
    )

    Setting.exchange_rate_provider = "yahoo_finance"
    refreshed = ExchangeRatePair.for_pair(from: "USD", to: "EUR")

    assert_nil refreshed.first_provider_rate_on
    assert_equal "yahoo_finance", refreshed.provider_name
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
  end
end
