require "test_helper"

class OnboardingProviderConfigurationTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
  end

  test "members and multi-family administrators cannot change global credentials" do
    with_self_hosting do
      OnboardingAiConfiguration.expects(:new).never
      [ users(:family_member), users(:family_admin) ].each do |user|
        sign_in user
        post configure_provider_onboarding_url, as: :json, params: payload
        assert_response :forbidden
      end
    end
  end

  test "managed installations reject credential configuration even for super admins" do
    @user.update!(role: :super_admin)
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    OnboardingAiConfiguration.expects(:new).never
    post configure_provider_onboarding_url, as: :json, params: payload
    assert_response :forbidden
  end

  test "authorized instance administrators save through the checked configuration flow" do
    @user.update!(role: :super_admin)
    configuration = mock("configuration", save: true, provider: "anthropic")
    OnboardingAiConfiguration.expects(:new).with(provider: "anthropic", api_key: "synthetic-key").returns(configuration)
    with_self_hosting do
      post configure_provider_onboarding_url, as: :json, params: payload
      assert_response :success
      assert_equal({ "status" => "saved", "provider" => "anthropic" }, response.parsed_body)
      assert_not_includes response.body, "synthetic-key"
    end
  end

  test "a legacy single-family administrator retains instance configuration access" do
    Family.stubs(:count).returns(1)
    configuration = mock("configuration", save: true, provider: "anthropic")
    OnboardingAiConfiguration.expects(:new).returns(configuration)
    with_self_hosting do
      post configure_provider_onboarding_url, as: :json, params: payload
      assert_response :success
    end
  end

  test "failed checks return safe errors without completing onboarding" do
    @user.update!(role: :super_admin, onboarded_at: nil)
    configuration = mock("configuration", save: false, error: "connection_failed")
    OnboardingAiConfiguration.expects(:new).returns(configuration)
    with_self_hosting do
      post configure_provider_onboarding_url, as: :json, params: payload
      assert_response :unprocessable_entity
      assert_equal "connection_failed", response.parsed_body["error"]
      assert_nil @user.reload.onboarded_at
      assert_not_includes response.body, "synthetic-key"
    end
  end

  private
    def payload
      { ai_configuration: { provider: "anthropic", api_key: "synthetic-key" } }
    end
end
