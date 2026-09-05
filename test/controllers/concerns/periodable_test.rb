require "test_helper"

class PeriodableTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)

    @start_date = 15.days.ago.to_date
    @end_date = 5.days.ago.to_date
    # The picker trigger shows the range's own dates, so derive the expected
    # label instead of hardcoding a format that shifts at the year boundary.
    @custom_label = Period.custom(start_date: @start_date, end_date: @end_date).label_range
  end

  test "start_date and end_date params build a custom period" do
    get root_path, params: { start_date: @start_date.to_s, end_date: @end_date.to_s }

    assert_response :success
    assert_select "button[aria-label='Time period: #{@custom_label}']"
  end

  test "invalid start_date or end_date falls back to last 30 days" do
    get root_path, params: { start_date: "not-a-date", end_date: @end_date.to_s }

    assert_response :success
    assert_select "button[aria-label='Time period: 30D']"
  end

  test "start_date and end_date range where start is after end falls back to last 30 days" do
    get root_path, params: { start_date: @end_date.to_s, end_date: @start_date.to_s }

    assert_response :success
    assert_select "button[aria-label='Time period: 30D']"
  end

  test "start_date without end_date is ignored and the user's default period wins" do
    @user.update!(default_period: "last_7_days")

    get root_path, params: { start_date: @start_date.to_s }

    assert_response :success
    assert_select "button[aria-label='Time period: #{Period.last_7_days.label_short}']"
  end

  test "start_date and end_date do not persist as the user's default period" do
    @user.update!(default_period: "last_7_days")

    get root_path, params: { start_date: @start_date.to_s, end_date: @end_date.to_s }

    assert_equal "last_7_days", @user.reload.default_period
  end

  test "start_date and end_date take precedence over a period param" do
    get root_path, params: { period: "last_7_days", start_date: @start_date.to_s, end_date: @end_date.to_s }

    assert_response :success
    assert_select "button[aria-label='Time period: #{@custom_label}']"
  end
end
