require "test_helper"

class OnboardingProviderConfigurationTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
  end

  test "members and guests cannot configure family credentials" do
    with_self_hosting do
      OnboardingAiConfiguration.expects(:new).never
      [ users(:family_member), users(:intro_user) ].each do |user|
        sign_in user
        %w[anthropic openrouter].each do |provider|
          post configure_provider_onboarding_url, as: :json, params: payload.deep_merge(
            ai_configuration: { provider: provider, model: "openai/gpt-4.1-mini" }
          )
          assert_response :forbidden
        end
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

  test "family administrators save through the checked configuration flow" do
    configuration = mock("configuration", save: true, provider: "anthropic")
    OnboardingAiConfiguration.expects(:new).with(family: @user.family, provider: "anthropic", api_key: "synthetic-key", model: nil).returns(configuration)
    with_self_hosting do
      post configure_provider_onboarding_url, as: :json, params: payload
      assert_response :success
      assert_equal({ "status" => "saved", "provider" => "anthropic" }, response.parsed_body)
      assert_not_includes response.body, "synthetic-key"
    end
  end

  test "OpenRouter model IDs are passed to the family checked configuration flow" do
    configuration = mock("configuration", save: true, provider: "openrouter")
    OnboardingAiConfiguration.expects(:new).with(
      family: @user.family, provider: "openrouter", api_key: "synthetic-key", model: "anthropic/claude-sonnet-4"
    ).returns(configuration)

    with_self_hosting do
      post configure_provider_onboarding_url, as: :json, params: payload.deep_merge(
        ai_configuration: { provider: "openrouter", model: "anthropic/claude-sonnet-4" }
      )
      assert_response :success
      assert_equal({ "status" => "saved", "provider" => "openrouter" }, response.parsed_body)
      assert_not_includes response.body, "synthetic-key"
    end
  end

  test "OpenRouter form restores this family's model without revealing credentials" do
    @user.family.create_ai_configuration!(provider: "openrouter", model: "openai/gpt-4.1-mini", api_key: "family-secret-key")
    families(:empty).create_ai_configuration!(provider: "openrouter", model: "anthropic/claude-sonnet-4", api_key: "other-family-secret-key")

    with_self_hosting do
      get tools_onboarding_url
      assert_response :success
      assert_select "p", text: I18n.t("onboardings.tools.tools_question")
      assert_select "legend", text: I18n.t("onboardings.tools.ai_question", product_name: Rails.configuration.x.product_name)
      assert_select "select#provider_configuration_provider option[selected][value='openrouter']", text: "OpenRouter/OpenAI-compatible API"
      assert_select "input#provider_configuration_model:not([name]):not([required])[value='openai/gpt-4.1-mini'][aria-required='true']"
      assert_select "label[for='provider_configuration_model']", text: I18n.t("onboardings.tools.provider_setup.model_label")
      assert_select "[data-onboarding-provider-target='modelFields']:not([hidden])"
      assert_not_includes response.body, "family-secret-key"
      assert_not_includes response.body, "other-family-secret-key"
      assert_not_includes response.body, "anthropic/claude-sonnet-4"
    end
  end

  test "forged family and configuration identifiers cannot redirect an admin or super admin save" do
    other = families(:empty).create_ai_configuration!(provider: "openai", api_key: "other-family-key")
    other_attributes = other.attributes
    configuration = stub("configuration", save: true, provider: "anthropic")
    OnboardingAiConfiguration.expects(:new).with(family: @user.family, provider: "anthropic", api_key: "synthetic-key", model: "untrusted-model").twice.returns(configuration)

    with_self_hosting do
      %w[admin super_admin].each do |role|
        @user.update!(role: role)
        sign_in @user
        post configure_provider_onboarding_url, as: :json, params: payload.deep_merge(
          family_id: other.family_id,
          ai_configuration: { id: other.id, family_id: other.family_id, model: "untrusted-model", endpoint: "https://untrusted.invalid" }
        )
        assert_response :success
        assert_equal other_attributes, other.reload.attributes
      end
    end
  end

  test "failed checks return safe errors without completing onboarding" do
    @user.update!(onboarded_at: nil)
    configuration = mock("configuration", save: false, error: "connection_failed")
    OnboardingAiConfiguration.expects(:new).with(family: @user.family, provider: "anthropic", api_key: "synthetic-key", model: nil).returns(configuration)
    with_self_hosting do
      post configure_provider_onboarding_url, as: :json, params: payload
      assert_response :unprocessable_entity
      assert_equal "connection_failed", response.parsed_body["error"]
      assert_nil @user.reload.onboarded_at
      assert_not_includes response.body, "synthetic-key"
    end
  end

  test "provider form uses the family selection without rendering either saved key" do
    @user.family.create_ai_configuration!(provider: "anthropic", api_key: "family-secret-key")
    Setting.stubs(:llm_provider).returns("openai")
    Setting.stubs(:openai_access_token).returns("installation-secret-key")

    with_self_hosting do
      get tools_onboarding_url
      assert_response :success
      assert_select "select#provider_configuration_provider:not([name]) option[selected][value='anthropic']"
      assert_select "input#provider_configuration_api_key[type='password']:not([name])" do |inputs|
        assert inputs.all? { |input| input["value"].blank? }
      end
      assert_select "input#provider_configuration_model:not([name]):not([required])[disabled]" do |inputs|
        assert inputs.all? { |input| input["value"].blank? }
      end
      assert_not_includes response.body, "family-secret-key"
      assert_not_includes response.body, "installation-secret-key"
      assert_select "[data-onboarding-provider-options-value]" do |elements|
        options = JSON.parse(elements.first["data-onboarding-provider-options-value"])
        assert options.values.none? { |option| option.key?("locked") }
      end
    end
  end

  test "family members do not see provider credential controls" do
    sign_in users(:family_member)
    with_self_hosting do
      get tools_onboarding_url
      assert_response :success
      assert_select "[data-controller='onboarding-provider']", count: 0
    end
  end

  test "provider API keys are filtered from request logging" do
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(payload)
    assert_equal "[FILTERED]", filtered[:ai_configuration][:api_key]
  end

  private
    def payload
      { ai_configuration: { provider: "anthropic", api_key: "synthetic-key" } }
    end
end
