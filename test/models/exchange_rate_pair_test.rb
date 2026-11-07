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
        provider_history_checked_from: 2.years.ago.to_date,
        provider_name: "twelve_data"
      )

      Setting.exchange_rate_provider = "yahoo_finance"
      refreshed = ExchangeRatePair.for_pair(from: "USD", to: "EUR")

      assert_nil refreshed.first_provider_rate_on
      assert_nil refreshed.provider_history_checked_from
      assert_equal "yahoo_finance", refreshed.provider_name
    ensure
      Setting.exchange_rate_provider = original_provider
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

  test "record_provider_history_checked_from moves earlier but not forward" do
    ExchangeRatePair.delete_all

    original_provider = Setting.exchange_rate_provider
    begin
      Setting.exchange_rate_provider = "twelve_data"
      ExchangeRatePair.create!(
        from_currency: "USD",
        to_currency: "EUR",
        provider_history_checked_from: 6.months.ago.to_date,
        provider_name: "twelve_data"
      )

      ExchangeRatePair.record_provider_history_checked_from(from: "USD", to: "EUR", date: 1.year.ago.to_date)
      pair = ExchangeRatePair.find_by!(from_currency: "USD", to_currency: "EUR")
      assert_equal 1.year.ago.to_date, pair.provider_history_checked_from

      ExchangeRatePair.record_provider_history_checked_from(from: "USD", to: "EUR", date: 3.months.ago.to_date)
      pair.reload
      assert_equal 1.year.ago.to_date, pair.provider_history_checked_from
    ensure
      Setting.exchange_rate_provider = original_provider
    end
  end

  test "stale provider imports cannot overwrite boundaries after a provider switch" do
    ExchangeRatePair.delete_all

    original_provider = Setting.exchange_rate_provider
    begin
      Setting.exchange_rate_provider = "twelve_data"
      stale_pair = ExchangeRatePair.for_pair(from: "USD", to: "EUR")
      stale_pair.update!(
        first_provider_rate_on: 6.months.ago.to_date,
        provider_history_checked_from: 6.months.ago.to_date
      )

      Setting.exchange_rate_provider = "yahoo_finance"
      current_pair = ExchangeRatePair.for_pair(from: "USD", to: "EUR")
      stale_lookup = ExchangeRatePair.for_pair(from: "USD", to: "EUR", provider_name: "twelve_data")
      assert_equal "yahoo_finance", stale_lookup.provider_name

      ExchangeRatePair.record_provider_history_checked_from(
        from: "USD",
        to: "EUR",
        date: 1.year.ago.to_date,
        provider_name: "twelve_data",
        pair: stale_pair
      )
      ExchangeRatePair.record_first_provider_rate_on(
        from: "USD",
        to: "EUR",
        date: 1.year.ago.to_date,
        provider_name: "twelve_data",
        pair: stale_pair
      )

      current_pair.reload
      assert_equal "yahoo_finance", current_pair.provider_name
      assert_nil current_pair.first_provider_rate_on
      assert_nil current_pair.provider_history_checked_from
    ensure
      Setting.exchange_rate_provider = original_provider
    end
  end
end
