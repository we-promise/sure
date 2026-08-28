require "test_helper"

class CurrentSessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
  end

  test "can update an allowed preferred tab" do
    put current_session_url, params: { current_session: { tab_key: "account_sidebar_tab", tab_value: "asset" } }
    assert_response :success
    session = @user.sessions.order(updated_at: :desc).first
    assert_equal "asset", session.get_preferred_tab("account_sidebar_tab")
  end

  test "ignores tab keys outside the allowlist" do
    put current_session_url, params: { current_session: { tab_key: "some_arbitrary_key", tab_value: "asset" } }
    assert_response :success
    session = @user.sessions.order(updated_at: :desc).first
    assert_nil session.get_preferred_tab("some_arbitrary_key")
  end
end
