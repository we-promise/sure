require "test_helper"

class PensionEntryTest < ActiveSupport::TestCase
  setup do
    @entry_2023 = pension_entries(:entry_2023)
    @entry_2024 = pension_entries(:entry_2024)
  end

  test "valid pension entry" do
    assert @entry_2024.valid?
  end

  test "requires recorded_at" do
    @entry_2024.recorded_at = nil
    assert_not @entry_2024.valid?
  end

  test "requires current_points" do
    @entry_2024.current_points = nil
    assert_not @entry_2024.valid?
  end

  test "current_points must be non-negative" do
    @entry_2024.current_points = -1
    assert_not @entry_2024.valid?
  end

  test "recorded_at must be unique per retirement_config" do
    duplicate = @entry_2024.retirement_config.pension_entries.build(
      recorded_at: @entry_2024.recorded_at,
      current_points: 10.0
    )
    assert_not duplicate.valid?
  end

  test "points_gained returns difference from previous entry" do
    assert_equal 1.0, @entry_2024.points_gained
  end

  test "points_gained returns current_points when no previous entry" do
    assert_equal 8.5, @entry_2023.points_gained
  end

  test "chronological scope orders by date ascending" do
    entries = @entry_2023.retirement_config.pension_entries.chronological
    assert_equal @entry_2023, entries.first
    assert_equal @entry_2024, entries.last
  end
end
