require "test_helper"

class OnboardingChoicesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_member)
  end

  test "updates only current user's starting point and assistant" do
    other = users(:family_admin)
    other_ai = other.ai_enabled
    patch user_url(other), params: { user: {
      starting_tools: [ "", "spreadsheets", "other" ], starting_tool_other: "Notebook",
      onboarding_ai_mode: "none", redirect_to: "home"
    } }
    assert_redirected_to root_url
    assert_equal [ "spreadsheets", "other" ], @user.reload.starting_tools
    assert_not @user.ai_enabled
    assert_equal other_ai, other.reload.ai_enabled
    assert_nil other.starting_tools
  end

  test "invalid submission does not complete onboarding" do
    @user.update!(onboarded_at: nil, set_onboarding_goals_at: nil)
    patch user_url(@user), as: :json, params: { user: {
      starting_tools: [ "nothing_yet", "ynab" ], onboarding_ai_mode: "builtin",
      onboarded_at: Time.current, set_onboarding_goals_at: Time.current
    } }
    assert_response :unprocessable_entity
    assert_nil @user.reload.onboarded_at
    assert_nil @user.set_onboarding_goals_at
  end

  test "invalid HTML submission keeps the wizard and submitted values" do
    patch user_url(@user), params: { user: {
      starting_tools: [ "other" ], starting_tool_other: "x" * 61,
      onboarding_ai_mode: "external"
    } }
    assert_response :unprocessable_entity
    assert_select "h1", text: /Make yourself at home/i
    assert_select "[role='alert']", text: /too long/i
    assert_select "input[name='user[onboarding_ai_mode]'][value='external'][checked]"
    assert_select "input[name='user[starting_tool_other]'][value='#{'x' * 61}']"
  end
end
