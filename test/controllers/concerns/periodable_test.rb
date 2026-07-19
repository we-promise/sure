require "test_helper"

class PeriodableTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "start_date and end_date params build a custom period" do
    get root_path, params: { start_date: "2026-06-01", end_date: "2026-06-15" }

    assert_response :success
    assert_select "button[aria-label='Time period: Custom']"
  end

  test "invalid start_date or end_date falls back to last 30 days" do
    get root_path, params: { start_date: "not-a-date", end_date: "2026-06-15" }

    assert_response :success
    assert_select "button[aria-label='Time period: 30D']"
  end

  test "start_date and end_date range where start is after end falls back to last 30 days" do
    get root_path, params: { start_date: "2026-06-15", end_date: "2026-06-01" }

    assert_response :success
    assert_select "button[aria-label='Time period: 30D']"
  end

  test "start_date and end_date do not persist as the user's default period" do
    @user.update!(default_period: "last_7_days")

    get root_path, params: { start_date: "2026-06-01", end_date: "2026-06-15" }

    assert_equal "last_7_days", @user.reload.default_period
  end

  test "start_date and end_date take precedence over a period param" do
    get root_path, params: { period: "last_7_days", start_date: "2026-06-01", end_date: "2026-06-15" }

    assert_response :success
    assert_select "button[aria-label='Time period: Custom']"
  end
end
