# frozen_string_literal: true

require "test_helper"

class RecurringTransactionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    sign_in @user
  end

  test "update_settings persists detection thresholds" do
    patch update_settings_recurring_transactions_path, params: {
      recurring_detection_lookback_months: 6,
      recurring_detection_min_occurrences: 4,
      recurring_detection_recent_window_days: 60,
      recurring_detection_day_tolerance: 3,
      recurring_detection_day_cluster_stddev: 7,
      recurring_detection_amount_tolerance_percent: 5
    }

    assert_redirected_to recurring_transactions_path
    @family.reload

    assert_equal 6, @family.recurring_detection_lookback_months
    assert_equal 4, @family.recurring_detection_min_occurrences
    assert_equal 60, @family.recurring_detection_recent_window_days
    assert_equal 3, @family.recurring_detection_day_tolerance
    assert_equal 7, @family.recurring_detection_day_cluster_stddev
    assert_equal 5, @family.recurring_detection_amount_tolerance_percent
  end

  test "index shows detection threshold form when enabled" do
    get recurring_transactions_path
    assert_response :success
    assert_select "input[name='recurring_detection_lookback_months']"
    assert_select "input[name='recurring_detection_amount_tolerance_percent']"
  end
end
