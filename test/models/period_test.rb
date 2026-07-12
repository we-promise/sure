require "test_helper"

class PeriodTest < ActiveSupport::TestCase
  test "raises validation error when start_date or end_date is missing" do
    error = assert_raises(ActiveModel::ValidationError) do
      Period.new(start_date: nil, end_date: nil)
    end

    assert_includes error.message, "Start date can't be blank"
    assert_includes error.message, "End date can't be blank"
  end

  test "raises validation error when start_date is not before end_date" do
    error = assert_raises(ActiveModel::ValidationError) do
      Period.new(start_date: Date.current, end_date: Date.current - 1.day)
    end

    assert_includes error.message, "Start date must be before end date"
  end

  test "can create custom period" do
    period = Period.new(start_date: Date.current - 15.days, end_date: Date.current)
    assert_equal "Custom Period", period.label
  end

  test "from_key returns period for valid key" do
    period = Period.from_key("last_30_days")
    assert_equal 30.days.ago.to_date, period.start_date
    assert_equal Date.current, period.end_date
  end

  test "from_key with invalid key and no fallback raises error" do
    error = assert_raises(Period::InvalidKeyError) do
      Period.from_key("invalid_key")
    end
  end

  test "label returns correct label for known period" do
    period = Period.from_key("last_30_days")
    assert_equal "Last 30 Days", period.label
  end

  test "label returns Custom Period for unknown period" do
    period = Period.new(start_date: Date.current - 15.days, end_date: Date.current)
    assert_equal "Custom Period", period.label
  end

  test "custom comparison label uses the current locale" do
    period = Period.new(start_date: Date.new(2026, 1, 2), end_date: Date.new(2026, 2, 3))

    I18n.with_locale(:en) do
      assert_equal "January 02, 2026 to February 03, 2026", period.comparison_label
    end

    I18n.with_locale(:de) do
      assert_equal "2. Januar 2026 bis 3. Februar 2026", period.comparison_label
    end
  end

  test "all_time period can be created" do
    period = Period.from_key("all_time")
    assert_equal "all_time", period.key
    assert_equal "All Time", period.label
    assert_equal "All", period.label_short
  end

  test "all_time period uses family's oldest entry date" do
    # Mock Current.family to return a family with oldest_entry_date
    mock_family = mock("family")
    mock_family.expects(:oldest_entry_date).returns(2.years.ago.to_date)
    Current.expects(:family).at_least_once.returns(mock_family)

    period = Period.from_key("all_time")
    assert_equal 2.years.ago.to_date, period.start_date
    assert_equal Date.current, period.end_date
  end

  test "current_month_for preserves the current_month key for custom-month families" do
    family = mock("family")
    family.stubs(:uses_custom_month_start?).returns(true)
    family.stubs(:current_custom_month_period).returns(
      Period.custom(start_date: Date.new(2026, 6, 5), end_date: Date.new(2026, 7, 4))
    )

    period = Period.current_month_for(family)
    assert_equal "current_month", period.key
    assert_equal Date.new(2026, 6, 5), period.start_date
    assert_equal Date.new(2026, 7, 4), period.end_date
  end

  test "last_month_for preserves the last_month key for custom-month families" do
    family = mock("family")
    family.stubs(:uses_custom_month_start?).returns(true)
    family.stubs(:custom_month_start_for).returns(Date.new(2026, 5, 5))
    family.stubs(:custom_month_end_for).returns(Date.new(2026, 6, 4))

    period = Period.last_month_for(family)
    assert_equal "last_month", period.key
  end

  test "all_time period uses fallback when no family or entries exist" do
    Current.expects(:family).returns(nil)

    period = Period.from_key("all_time")
    assert_equal 5.years.ago.to_date, period.start_date
    assert_equal Date.current, period.end_date
  end

  test "all_time period uses fallback when oldest_entry_date equals current date" do
    # Mock a family that has no historical entries (oldest_entry_date returns today)
    mock_family = mock("family")
    mock_family.expects(:oldest_entry_date).returns(Date.current)
    Current.expects(:family).at_least_once.returns(mock_family)

    period = Period.from_key("all_time")
    assert_equal 5.years.ago.to_date, period.start_date
    assert_equal Date.current, period.end_date
  end
end
