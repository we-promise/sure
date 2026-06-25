require "test_helper"

class BasisTradeSnapshotTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "validates required attributes" do
    snapshot = BasisTradeSnapshot.new

    assert_not snapshot.valid?
    assert_includes snapshot.errors[:family], "must exist"
    assert_includes snapshot.errors[:recorded_at], "can't be blank"
    assert_includes snapshot.errors[:currency], "can't be blank"
  end

  test "validates uniqueness of recorded_at scoped to family" do
    recorded_at = Time.zone.parse("2026-06-20 12:00:00")
    BasisTradeSnapshot.create!(family: @family, recorded_at:, currency: "USD")

    duplicate = BasisTradeSnapshot.new(family: @family, recorded_at:, currency: "USD")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:recorded_at], "has already been taken"
  end

  test "orders chronologically" do
    later = BasisTradeSnapshot.create!(family: @family, recorded_at: Time.zone.parse("2026-06-21 12:00:00"), currency: "USD")
    earlier = BasisTradeSnapshot.create!(family: @family, recorded_at: Time.zone.parse("2026-06-20 12:00:00"), currency: "USD")

    assert_equal [ earlier, later ], BasisTradeSnapshot.for_family(@family).chronological.to_a
  end

  test "filters within a time range" do
    inside = BasisTradeSnapshot.create!(family: @family, recorded_at: Time.zone.parse("2026-06-20 12:00:00"), currency: "USD")
    BasisTradeSnapshot.create!(family: @family, recorded_at: Time.zone.parse("2026-06-10 12:00:00"), currency: "USD")

    results = BasisTradeSnapshot.between(Time.zone.parse("2026-06-15 00:00:00"), Time.zone.parse("2026-06-21 00:00:00"))

    assert_equal [ inside ], results.to_a
  end
end
