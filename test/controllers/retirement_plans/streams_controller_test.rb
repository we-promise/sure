require "test_helper"

class RetirementPlans::StreamsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @other = users(:family_member)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    RetirementPlan.where(user: [ @user, @other ]).delete_all
    sign_in @user
    ensure_tailwind_build
  end

  test "a user without preview access is turned away from the streams" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))

    get new_retirement_plan_stream_url
    assert_redirected_to root_path

    assert_no_difference "RetirementPlan::Stream.count" do
      post retirement_plan_streams_url, params: { retirement_plan_stream: { kind: "expense", name: "x", annual_amount: 1 } }
    end
    assert_redirected_to root_path
  end

  test "a stream is added to the signed-in user's own plan, and listed on the planner" do
    assert_difference "RetirementPlan::Stream.count", 1 do
      post retirement_plan_streams_url, params: { retirement_plan_stream: {
        kind: "income", name: "State pension", annual_amount: "11000", start_year: "2047", indexed: "1"
      } }
    end
    assert_redirected_to retirement_plan_path

    stream = RetirementPlan.find_by!(user: @user).streams.sole
    assert_equal [ "income", BigDecimal("11000"), 2047, "manual" ], [ stream.kind, stream.annual_amount, stream.start_year, stream.source ]

    get retirement_plan_url
    assert_select "#retirement-plan-streams tr[data-stream-id='#{stream.id}']", text: /State pension/
  end

  test "an invalid stream is refused and nothing is written, not even the plan" do
    assert_no_difference [ "RetirementPlan::Stream.count", "RetirementPlan.count" ] do
      post retirement_plan_streams_url, params: { retirement_plan_stream: { kind: "expense", name: "", annual_amount: "0" } }
    end

    assert_response :unprocessable_entity
  end

  test "another user's stream cannot be opened, changed or deleted" do
    others = RetirementPlan.create!(user: @other).streams.create!(kind: "expense", name: "Theirs", annual_amount: 5, source: "manual")

    get edit_retirement_plan_stream_url(others)
    assert_response :not_found
    patch retirement_plan_stream_url(others), params: { retirement_plan_stream: { annual_amount: "1" } }
    assert_response :not_found
    delete retirement_plan_stream_url(others)
    assert_response :not_found

    assert_equal BigDecimal("5"), others.reload.annual_amount
  end

  test "a user's own stream can be changed and deleted" do
    stream = RetirementPlan.create!(user: @user).streams.create!(kind: "expense", name: "Mine", annual_amount: 5, source: "manual")

    get edit_retirement_plan_stream_url(stream)
    assert_response :success

    patch retirement_plan_stream_url(stream), params: { retirement_plan_stream: { annual_amount: "7" } }
    assert_equal BigDecimal("7"), stream.reload.annual_amount

    patch retirement_plan_stream_url(stream), params: { retirement_plan_stream: { annual_amount: "0" } }
    assert_response :unprocessable_entity
    assert_equal BigDecimal("7"), stream.reload.annual_amount

    assert_difference "RetirementPlan::Stream.count", -1 do
      delete retirement_plan_stream_url(stream)
    end
  end
end
