require "test_helper"
require "ostruct"

class ExchangeRate::ImporterTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @provider = mock
  end

  test "syncs missing rates from provider" do
    ExchangeRate.delete_all

    provider_response = provider_success_response([
      OpenStruct.new(from: "USD", to: "EUR", date: 2.days.ago.to_date, rate: 1.3),
      OpenStruct.new(from: "USD", to: "EUR", date: 1.day.ago.to_date, rate: 1.4),
      OpenStruct.new(from: "USD", to: "EUR", date: Date.current, rate: 1.5)
    ])

    @provider.expects(:fetch_exchange_rates)
             .with(from: "USD", to: "EUR", start_date: get_provider_fetch_start_date(2.days.ago.to_date), end_date: Date.current)
             .returns(provider_response)

    ExchangeRate::Importer.new(
      exchange_rate_provider: @provider,
      from: "USD",
      to: "EUR",
      start_date: 2.days.ago.to_date,
      end_date: Date.current
    ).import_provider_rates

    db_rates = ExchangeRate.where(from_currency: "USD", to_currency: "EUR", date: 2.days.ago.to_date..Date.current)
                           .order(:date)

    assert_equal 3, db_rates.count
    assert_equal 1.3, db_rates[0].rate
    assert_equal 1.4, db_rates[1].rate
    assert_equal 1.5, db_rates[2].rate
  end

  test "syncs diff when some rates already exist" do
    ExchangeRate.delete_all

    # Pre-populate DB with the first two days
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: 3.days.ago.to_date, rate: 1.2)
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: 2.days.ago.to_date, rate: 1.25)

    provider_response = provider_success_response([
      OpenStruct.new(from: "USD", to: "EUR", date: 1.day.ago.to_date, rate: 1.3)
    ])

    @provider.expects(:fetch_exchange_rates)
             .with(from: "USD", to: "EUR", start_date: get_provider_fetch_start_date(1.day.ago.to_date), end_date: Date.current)
             .returns(provider_response)

    ExchangeRate::Importer.new(
      exchange_rate_provider: @provider,
      from: "USD",
      to: "EUR",
      start_date: 3.days.ago.to_date,
      end_date: Date.current
    ).import_provider_rates

    forward_rates = ExchangeRate.where(from_currency: "USD", to_currency: "EUR").order(:date)
    assert_equal 4, forward_rates.count
    assert_equal [ 1.2, 1.25, 1.3, 1.3 ], forward_rates.map(&:rate)
  end

  test "no provider calls when all rates exist" do
    ExchangeRate.delete_all

    (3.days.ago.to_date..Date.current).each_with_index do |date, idx|
      ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date:, rate: 1.2 + idx * 0.01)
    end

    @provider.expects(:fetch_exchange_rates).never

    ExchangeRate::Importer.new(
      exchange_rate_provider: @provider,
      from: "USD",
      to: "EUR",
      start_date: 3.days.ago.to_date,
      end_date: Date.current
    ).import_provider_rates
  end

  # A helpful "reset" option for when we need to refresh provider data
  test "full upsert if clear_cache is true" do
    ExchangeRate.delete_all

    # Seed DB with stale data
    (2.days.ago.to_date..Date.current).each do |date|
      ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date:, rate: 1.0)
    end

    provider_response = provider_success_response([
      OpenStruct.new(from: "USD", to: "EUR", date: 2.days.ago.to_date, rate: 1.3),
      OpenStruct.new(from: "USD", to: "EUR", date: 1.day.ago.to_date, rate: 1.4),
      OpenStruct.new(from: "USD", to: "EUR", date: Date.current,        rate: 1.5)
    ])

    @provider.expects(:fetch_exchange_rates)
             .with(from: "USD", to: "EUR", start_date: get_provider_fetch_start_date(2.days.ago.to_date), end_date: Date.current)
             .returns(provider_response)

    ExchangeRate::Importer.new(
      exchange_rate_provider: @provider,
      from: "USD",
      to: "EUR",
      start_date: 2.days.ago.to_date,
      end_date: Date.current,
      clear_cache: true
    ).import_provider_rates

    db_rates = ExchangeRate.where(from_currency: "USD", to_currency: "EUR").order(:date)
    assert_equal [ 1.3, 1.4, 1.5 ], db_rates.map(&:rate)
  end

  test "clamps end_date to today when future date is provided" do
    ExchangeRate.delete_all

    future_date = Date.current + 3.days

    provider_response = provider_success_response([
      OpenStruct.new(from: "USD", to: "EUR", date: Date.current, rate: 1.6)
    ])

    @provider.expects(:fetch_exchange_rates)
             .with(from: "USD", to: "EUR", start_date: get_provider_fetch_start_date(Date.current), end_date: Date.current)
             .returns(provider_response)

    ExchangeRate::Importer.new(
      exchange_rate_provider: @provider,
      from: "USD",
      to: "EUR",
      start_date: Date.current,
      end_date: future_date
    ).import_provider_rates

    # 1 forward rate + 1 inverse rate
    assert_equal 2, ExchangeRate.count
  end

  test "upserts inverse rates alongside forward rates" do
    ExchangeRate.delete_all

    provider_response = provider_success_response([
      OpenStruct.new(from: "USD", to: "EUR", date: Date.current, rate: 0.85)
    ])

    @provider.expects(:fetch_exchange_rates)
             .with(from: "USD", to: "EUR", start_date: get_provider_fetch_start_date(Date.current), end_date: Date.current)
             .returns(provider_response)

    ExchangeRate::Importer.new(
      exchange_rate_provider: @provider,
      from: "USD",
      to: "EUR",
      start_date: Date.current,
      end_date: Date.current
    ).import_provider_rates

    forward = ExchangeRate.find_by(from_currency: "USD", to_currency: "EUR", date: Date.current)
    inverse = ExchangeRate.find_by(from_currency: "EUR", to_currency: "USD", date: Date.current)

    assert_not_nil forward, "Forward rate should be stored"
    assert_not_nil inverse, "Inverse rate should be computed and stored"
    assert_in_delta 0.85, forward.rate.to_f, 0.0001
    assert_in_delta (1.0 / 0.85), inverse.rate.to_f, 0.0001
  end

  test "fresh provider values overwrite stale DB rows within the sync window" do
    ExchangeRate.delete_all

    # Day 1: correct, Day 2: missing (gap), Day 3: stale/wrong, Today: missing.
    # The gap at day 2 causes effective_start_date = day 2, so the LOCF loop
    # covers days 2-4. Day 3's stale value should be overwritten by the
    # provider's fresh value (provider wins over DB).
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: 3.days.ago.to_date, rate: 0.86)
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: 1.day.ago.to_date, rate: 0.9253)

    provider_response = provider_success_response([
      OpenStruct.new(from: "USD", to: "EUR", date: 2.days.ago.to_date, rate: 0.87),
      OpenStruct.new(from: "USD", to: "EUR", date: 1.day.ago.to_date, rate: 0.88),
      OpenStruct.new(from: "USD", to: "EUR", date: Date.current,        rate: 0.89)
    ])

    @provider.expects(:fetch_exchange_rates)
             .with(from: "USD", to: "EUR", start_date: get_provider_fetch_start_date(2.days.ago.to_date), end_date: Date.current)
             .returns(provider_response)

    ExchangeRate::Importer.new(
      exchange_rate_provider: @provider,
      from: "USD",
      to: "EUR",
      start_date: 3.days.ago.to_date,
      end_date: Date.current
    ).import_provider_rates

    db_rates = ExchangeRate.where(from_currency: "USD", to_currency: "EUR").order(:date)
    assert_equal 4, db_rates.count
    assert_equal [ 0.86, 0.87, 0.88, 0.89 ], db_rates.map(&:rate)
  end

  test "backfills missing inverse rates when forward rates already exist" do
    ExchangeRate.delete_all

    # Create forward rates without inverses (simulating pre-inverse-computation data)
    (2.days.ago.to_date..Date.current).each_with_index do |date, idx|
      ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: date, rate: 0.85 + idx * 0.01)
    end

    # All forward rates exist, so no provider call — but inverse backfill should fire
    @provider.expects(:fetch_exchange_rates).never

    ExchangeRate::Importer.new(
      exchange_rate_provider: @provider,
      from: "USD",
      to: "EUR",
      start_date: 2.days.ago.to_date,
      end_date: Date.current
    ).import_provider_rates

    inverse_rates = ExchangeRate.where(from_currency: "EUR", to_currency: "USD").order(:date)
    assert_equal 3, inverse_rates.count

    inverse_rates.each do |inv|
      forward = ExchangeRate.find_by(from_currency: "USD", to_currency: "EUR", date: inv.date)
      assert_in_delta (1.0 / forward.rate.to_f), inv.rate.to_f, 0.0001
    end
  end

  test "logs error and imports nothing when provider returns only zero and nil rates" do
    ExchangeRate.delete_all
    ExchangeRatePair.delete_all

    provider_response = provider_success_response([
      OpenStruct.new(from: "USD", to: "EUR", date: 2.days.ago.to_date, rate: 0),
      OpenStruct.new(from: "USD", to: "EUR", date: 1.day.ago.to_date,  rate: nil),
      OpenStruct.new(from: "USD", to: "EUR", date: Date.current,        rate: 0)
    ])

    @provider.expects(:fetch_exchange_rates).returns(provider_response)

    ExchangeRate::Importer.new(
      exchange_rate_provider: @provider,
      from: "USD",
      to: "EUR",
      start_date: 2.days.ago.to_date,
      end_date: Date.current
    ).import_provider_rates

    assert_equal 0, ExchangeRate.where(from_currency: "USD", to_currency: "EUR").count
  end

  test "handles rate limit error gracefully" do
    ExchangeRate.delete_all

    rate_limit_error = Provider::TwelveData::RateLimitError.new("Rate limit exceeded")

    @provider.expects(:fetch_exchange_rates).once.returns(
      provider_error_response(rate_limit_error)
    )

    # Should not raise — logs warning and returns without importing
    ExchangeRate::Importer.new(
      exchange_rate_provider: @provider,
      from: "USD",
      to: "EUR",
      start_date: Date.current,
      end_date: Date.current
    ).import_provider_rates

    assert_equal 0, ExchangeRate.count, "No rates should be imported on rate limit error"
  end

  # === Clamping tests (Phase 2) ===

  test "advances gapfill start when pair predates provider history" do
    ExchangeRate.delete_all
    ExchangeRatePair.delete_all

    # Provider only returns rates starting 5 days ago (simulating limited history).
    # start_date is 30 days ago — provider can't serve anything before 5 days ago.
    provider_response = provider_success_response([
      OpenStruct.new(from: "USD", to: "EUR", date: 5.days.ago.to_date, rate: 1.1),
      OpenStruct.new(from: "USD", to: "EUR", date: 4.days.ago.to_date, rate: 1.2),
      OpenStruct.new(from: "USD", to: "EUR", date: 3.days.ago.to_date, rate: 1.3),
      OpenStruct.new(from: "USD", to: "EUR", date: 2.days.ago.to_date, rate: 1.4),
      OpenStruct.new(from: "USD", to: "EUR", date: 1.day.ago.to_date,  rate: 1.5),
      OpenStruct.new(from: "USD", to: "EUR", date: Date.current,        rate: 1.6)
    ])

    @provider.expects(:fetch_exchange_rates).returns(provider_response)

    ExchangeRate::Importer.new(
      exchange_rate_provider: @provider,
      from: "USD",
      to: "EUR",
      start_date: 30.days.ago.to_date,
      end_date: Date.current
    ).import_provider_rates

    forward_rates = ExchangeRate.where(from_currency: "USD", to_currency: "EUR").order(:date)
    assert_equal 6, forward_rates.count
    assert_equal 5.days.ago.to_date, forward_rates.first.date

    pair = ExchangeRatePair.find_by(from_currency: "USD", to_currency: "EUR")
    assert_equal 5.days.ago.to_date, pair.first_provider_rate_on
  end

  test "pre-coverage fallback picks earliest valid provider row, skipping zero leaders" do
    ExchangeRate.delete_all
    ExchangeRatePair.delete_all

    provider_response = provider_success_response([
      OpenStruct.new(from: "USD", to: "EUR", date: 4.days.ago.to_date, rate: 0),
      OpenStruct.new(from: "USD", to: "EUR", date: 3.days.ago.to_date, rate: nil),
      OpenStruct.new(from: "USD", to: "EUR", date: 2.days.ago.to_date, rate: 1.3),
      OpenStruct.new(from: "USD", to: "EUR", date: 1.day.ago.to_date,  rate: 1.4),
      OpenStruct.new(from: "USD", to: "EUR", date: Date.current,        rate: 1.5)
    ])

    @provider.expects(:fetch_exchange_rates).returns(provider_response)

    ExchangeRate::Importer.new(
      exchange_rate_provider: @provider,
      from: "USD",
      to: "EUR",
      start_date: 30.days.ago.to_date,
      end_date: Date.current
    ).import_provider_rates

    pair = ExchangeRatePair.find_by(from_currency: "USD", to_currency: "EUR")
    assert_equal 2.days.ago.to_date, pair.first_provider_rate_on
  end

  test "first_provider_rate_on is moved earlier when provider extends backward coverage" do
    ExchangeRate.delete_all
    ExchangeRatePair.delete_all

    ExchangeRatePair.create!(
      from_currency: "USD", to_currency: "EUR",
      first_provider_rate_on: 3.days.ago.to_date,
      provider_name: Setting.exchange_rate_provider.to_s
    )

    # Provider now returns an earlier date with clear_cache
    provider_response = provider_success_response([
      OpenStruct.new(from: "USD", to: "EUR", date: 10.days.ago.to_date, rate: 1.0),
      OpenStruct.new(from: "USD", to: "EUR", date: 9.days.ago.to_date,  rate: 1.1),
      OpenStruct.new(from: "USD", to: "EUR", date: Date.current,         rate: 1.5)
    ])

    @provider.expects(:fetch_exchange_rates).returns(provider_response)

    ExchangeRate::Importer.new(
      exchange_rate_provider: @provider,
      from: "USD",
      to: "EUR",
      start_date: 30.days.ago.to_date,
      end_date: Date.current,
      clear_cache: true
    ).import_provider_rates

    pair = ExchangeRatePair.find_by!(from_currency: "USD", to_currency: "EUR")
    assert_equal 10.days.ago.to_date, pair.first_provider_rate_on
  end

  test "first_provider_rate_on is NOT moved forward when provider shrinks coverage" do
    ExchangeRate.delete_all
    ExchangeRatePair.delete_all

    ExchangeRatePair.create!(
      from_currency: "USD", to_currency: "EUR",
      first_provider_rate_on: 10.days.ago.to_date,
      provider_name: Setting.exchange_rate_provider.to_s
    )

    # Provider now only returns from 3 days ago (shrunk window)
    provider_response = provider_success_response([
      OpenStruct.new(from: "USD", to: "EUR", date: 3.days.ago.to_date, rate: 1.3),
      OpenStruct.new(from: "USD", to: "EUR", date: Date.current,        rate: 1.5)
    ])

    @provider.expects(:fetch_exchange_rates).returns(provider_response)

    ExchangeRate::Importer.new(
      exchange_rate_provider: @provider,
      from: "USD",
      to: "EUR",
      start_date: 30.days.ago.to_date,
      end_date: Date.current,
      clear_cache: true
    ).import_provider_rates

    pair = ExchangeRatePair.find_by!(from_currency: "USD", to_currency: "EUR")
    assert_equal 10.days.ago.to_date, pair.first_provider_rate_on
  end

  test "incremental sync on pre-coverage pair skips pre-coverage window" do
    ExchangeRate.delete_all
    ExchangeRatePair.delete_all

    clamp_date = 5.days.ago.to_date
    ExchangeRatePair.create!(
      from_currency: "USD", to_currency: "EUR",
      first_provider_rate_on: clamp_date,
      provider_name: Setting.exchange_rate_provider.to_s
    )

    # Seed DB with rates from clamp to yesterday
    (clamp_date..1.day.ago.to_date).each_with_index do |date, idx|
      ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: date, rate: 1.0 + idx * 0.01)
    end

    # Provider returns today's rate
    provider_response = provider_success_response([
      OpenStruct.new(from: "USD", to: "EUR", date: Date.current, rate: 1.5)
    ])

    @provider.expects(:fetch_exchange_rates)
             .with(from: "USD", to: "EUR",
                   start_date: get_provider_fetch_start_date(Date.current),
                   end_date: Date.current)
             .returns(provider_response)

    ExchangeRate::Importer.new(
      exchange_rate_provider: @provider,
      from: "USD",
      to: "EUR",
      start_date: 30.days.ago.to_date,
      end_date: Date.current
    ).import_provider_rates

    assert_equal 1.5, ExchangeRate.find_by(from_currency: "USD", to_currency: "EUR", date: Date.current).rate
  end

  test "skips provider call when all rates exist in clamped range" do
    ExchangeRate.delete_all
    ExchangeRatePair.delete_all

    clamp_date = 3.days.ago.to_date
    ExchangeRatePair.create!(
      from_currency: "USD", to_currency: "EUR",
      first_provider_rate_on: clamp_date,
      provider_name: Setting.exchange_rate_provider.to_s
    )

    (clamp_date..Date.current).each_with_index do |date, idx|
      ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: date, rate: 1.0 + idx * 0.01)
    end

    @provider.expects(:fetch_exchange_rates).never

    ExchangeRate::Importer.new(
      exchange_rate_provider: @provider,
      from: "USD",
      to: "EUR",
      start_date: 30.days.ago.to_date,
      end_date: Date.current
    ).import_provider_rates
  end

  test "clamps provider fetch to max_history_days when provider exposes limit" do
    ExchangeRate.delete_all
    ExchangeRatePair.delete_all

    @provider.stubs(:max_history_days).returns(10)

    provider_response = provider_success_response([
      OpenStruct.new(from: "USD", to: "EUR", date: Date.current, rate: 1.5)
    ])

    expected_start = Date.current - 10.days
    @provider.expects(:fetch_exchange_rates)
             .with(from: "USD", to: "EUR",
                   start_date: expected_start,
                   end_date: Date.current)
             .returns(provider_response)

    ExchangeRate::Importer.new(
      exchange_rate_provider: @provider,
      from: "USD",
      to: "EUR",
      start_date: 60.days.ago.to_date,
      end_date: Date.current
    ).import_provider_rates
  end

  private
    def get_provider_fetch_start_date(start_date)
      start_date - ExchangeRate::Importer::PROVISIONAL_LOOKBACK_DAYS.days
    end
end
