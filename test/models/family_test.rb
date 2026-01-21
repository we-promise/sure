require "test_helper"

class FamilyTest < ActiveSupport::TestCase
  include SyncableInterfaceTest

  def setup
    @syncable = families(:dylan_family)
  end

  test "available_merchants includes family merchants without transactions" do
    family = families(:dylan_family)

    new_merchant = family.merchants.create!(name: "New Test Merchant")

    assert_includes family.available_merchants, new_merchant
  end

  test "validates month_start_day inclusion in 1..28" do
    family = families(:dylan_family)

    family.month_start_day = 0
    assert_not family.valid?

    family.month_start_day = 29
    assert_not family.valid?

    family.month_start_day = 15
    assert family.valid?
  end

  test "uses_custom_month_start? returns false when month_start_day is 1" do
    family = families(:dylan_family)
    family.month_start_day = 1

    assert_not family.uses_custom_month_start?
  end

  test "uses_custom_month_start? returns true when month_start_day is not 1" do
    family = families(:dylan_family)
    family.month_start_day = 15

    assert family.uses_custom_month_start?
  end

  test "custom_month_start_for returns correct start date when day is after month_start_day" do
    family = families(:dylan_family)
    family.month_start_day = 15

    # If today is Feb 20, the custom month start is Feb 15
    date = Date.new(2026, 2, 20)
    assert_equal Date.new(2026, 2, 15), family.custom_month_start_for(date)
  end

  test "custom_month_start_for returns correct start date when day is before month_start_day" do
    family = families(:dylan_family)
    family.month_start_day = 15

    # If today is Feb 10, the custom month start is Jan 15
    date = Date.new(2026, 2, 10)
    assert_equal Date.new(2026, 1, 15), family.custom_month_start_for(date)
  end

  test "custom_month_end_for returns correct end date" do
    family = families(:dylan_family)
    family.month_start_day = 15

    # If today is Feb 20, the custom month end is Mar 14
    date = Date.new(2026, 2, 20)
    assert_equal Date.new(2026, 3, 14), family.custom_month_end_for(date)
  end

  test "current_custom_month_period returns period with correct boundaries" do
    family = families(:dylan_family)
    family.month_start_day = 15

    period = family.current_custom_month_period

    assert_equal family.custom_month_start_for(Date.current), period.start_date
    assert period.end_date <= family.custom_month_end_for(Date.current)
    assert period.end_date <= Date.current
  end
end
