require "test_helper"

class BasisTradeSeriesBuilderTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "returns an empty payload shape when there are no snapshots" do
    payload = BasisTradeSeriesBuilder.new(family: @family).payload

    assert_equal @family.primary_currency_code, payload[:currency]
    assert_equal [ ], payload[:points]
    assert_equal({ spot: 0.0, short: 0.0, funding: 0.0, rewards: 0.0, combined: 0.0 }, payload[:totals])
  end

  test "builds points in chronological order with combined totals" do
    BasisTradeSnapshot.create!(
      family: @family,
      recorded_at: Time.zone.parse("2026-06-21 12:00:00"),
      spot_leg_cents: 1_550_000,
      short_leg_cents: -30_000,
      funding_accrued_cents: 15_000,
      rewards_accrued_cents: 5_000,
      currency: "USD"
    )
    BasisTradeSnapshot.create!(
      family: @family,
      recorded_at: Time.zone.parse("2026-06-20 12:00:00"),
      spot_leg_cents: 1_500_000,
      short_leg_cents: -25_000,
      funding_accrued_cents: 12_000,
      rewards_accrued_cents: 4_000,
      currency: "USD"
    )

    payload = BasisTradeSeriesBuilder.new(family: @family).payload

    assert_equal [ "2026-06-20", "2026-06-21" ], payload[:points].map { |point| point[:date] }
    assert_equal 1491.0, payload[:points].first[:combined]
    assert_equal 1540.0, payload[:points].last[:combined]
  end

  test "uses the latest snapshot for totals" do
    BasisTradeSnapshot.create!(
      family: @family,
      recorded_at: Time.zone.parse("2026-06-20 12:00:00"),
      spot_leg_cents: 1_500_000,
      short_leg_cents: -25_000,
      funding_accrued_cents: 12_000,
      rewards_accrued_cents: 4_000,
      currency: "USD"
    )
    BasisTradeSnapshot.create!(
      family: @family,
      recorded_at: Time.zone.parse("2026-06-21 12:00:00"),
      spot_leg_cents: 1_550_000,
      short_leg_cents: -30_000,
      funding_accrued_cents: 15_000,
      rewards_accrued_cents: 5_000,
      currency: "USD"
    )

    totals = BasisTradeSeriesBuilder.new(family: @family).payload[:totals]

    assert_equal({ spot: 1550.0, short: -30.0, funding: 15.0, rewards: 5.0, combined: 1540.0 }, totals)
  end

  test "filters payload points by date range" do
    BasisTradeSnapshot.create!(
      family: @family,
      recorded_at: Time.zone.parse("2026-06-10 12:00:00"),
      spot_leg_cents: 1_400_000,
      currency: "USD"
    )
    inside = BasisTradeSnapshot.create!(
      family: @family,
      recorded_at: Time.zone.parse("2026-06-20 12:00:00"),
      spot_leg_cents: 1_500_000,
      currency: "USD"
    )

    payload = BasisTradeSeriesBuilder.new(
      family: @family,
      start_date: Date.new(2026, 6, 15),
      end_date: Date.new(2026, 6, 21)
    ).payload

    assert_equal [ inside.recorded_at.to_date.iso8601 ], payload[:points].map { |point| point[:date] }
  end
end
