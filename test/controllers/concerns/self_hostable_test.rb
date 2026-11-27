require "test_helper"

# SelfHostable's `verify_self_host_config` prepended before_action gates every
# request on a reachable Redis when the app runs self-hosted. See
# app/controllers/concerns/self_hostable.rb.
class SelfHostableTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:empty)
  end

  test "lets the request through when self hosted and redis is reachable" do
    with_self_hosting do
      get privacy_path
      assert_response :success
    end
  end

  test "does not check redis when not self hosted" do
    ApplicationController.any_instance.expects(:redis_connected?).never

    get privacy_path
    assert_response :success
  end

  test "redirects to the redis configuration error page when self hosted and redis is unreachable" do
    with_self_hosting(redis_connected: false) do
      get privacy_path
      assert_redirected_to redis_configuration_error_path
    end
  end

  test "redirects home from the error page once redis becomes reachable" do
    with_self_hosting(redis_connected: true) do
      get redis_configuration_error_path
      assert_redirected_to root_path
      assert_equal I18n.t("concerns.self_hostable.redis_configured"), flash[:notice]
    end
  end

  test "renders the error page instead of redirecting to itself when redis is unreachable" do
    with_self_hosting(redis_connected: false) do
      get redis_configuration_error_path
      assert_response :success
    end
  end
end
