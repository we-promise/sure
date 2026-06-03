require "test_helper"

class Retirement::AdjustmentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @user.family.update!(retirement_disabled: false)
    sign_in @user
    ensure_tailwind_build
    @plan = Goal::Retirement.for_owner(@user)
  end

  test "404 when family retirement disabled" do
    @user.family.update!(retirement_disabled: true)
    get new_retirement_adjustment_url
    assert_response :not_found
  end

  test "new renders the form" do
    get new_retirement_adjustment_url
    assert_response :success
  end

  test "edit renders the form" do
    get edit_retirement_adjustment_url(goal_retirement_adjustments(:mortgage_paid_off))
    assert_response :success
  end

  test "create adds an adjustment" do
    assert_difference -> { @plan.adjustments.count }, 1 do
      post retirement_adjustments_url, params: { goal_retirement_adjustment: {
        label: "Healthcare", amount_today: 220, currency: "USD", from_age: 65, ordinal: 5
      } }
    end
    assert_redirected_to retirement_path
  end

  test "update edits an adjustment" do
    adjustment = goal_retirement_adjustments(:mortgage_paid_off)
    patch retirement_adjustment_url(adjustment), params: { goal_retirement_adjustment: { label: "Renamed" } }
    assert_redirected_to retirement_path
    assert_equal "Renamed", adjustment.reload.label
  end

  test "destroy removes an adjustment" do
    adjustment = @plan.adjustments.create!(label: "Temp", amount_today: -1, currency: "USD", from_age: 60, ordinal: 9)
    assert_difference -> { @plan.adjustments.count }, -1 do
      delete retirement_adjustment_url(adjustment)
    end
  end
end
