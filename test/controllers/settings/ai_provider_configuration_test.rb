require "test_helper"

class Settings::AiProviderConfigurationTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
  end

  test "self-hosted family admins see provider controls and existing prompt fields" do
    @user.family.create_ai_configuration!(provider: "anthropic", api_key: "hidden-family-key")

    with_self_hosting do
      get settings_ai_prompts_path
      assert_response :success
      assert_select "[data-onboarding-provider-url-value='#{configure_provider_settings_ai_prompts_path}']"
      assert_select "select#provider_configuration_provider option[selected][value='anthropic']"
      assert_select "input#provider_configuration_api_key[type='password']:not([name])" do |inputs|
        assert inputs.all? { |input| input["value"].blank? }
      end
      assert_select "[data-controller='onboarding-provider'] fieldset[disabled]", count: 0
      assert_select "textarea#family_ai_prompt_chat_system"
      assert_not_includes response.body, "hidden-family-key"
    end
  end

  test "OpenRouter settings restore the saved model and keep the key blank" do
    @user.family.create_ai_configuration!(provider: "openrouter", model: "anthropic/claude-sonnet-4", api_key: "hidden-family-key")

    with_self_hosting do
      get settings_ai_prompts_path
      assert_response :success
      assert_select "select#provider_configuration_provider option[selected][value='openrouter']", text: "OpenAI-compatible API"
      assert_select "input#provider_configuration_model:not([name])[value='anthropic/claude-sonnet-4']:not([disabled])"
      assert_select "label[for='provider_configuration_model']", text: I18n.t("onboardings.tools.provider_setup.model_label")
      assert_select "input#provider_configuration_api_key" do |inputs|
        assert inputs.all? { |input| input["value"].blank? }
      end
      assert_not_includes response.body, "hidden-family-key"
    end
  end

  test "OpenRouter saves the chosen model for only the current family" do
    other = families(:empty).create_ai_configuration!(provider: "openrouter", model: "anthropic/claude-sonnet-4", api_key: "other-family-key")
    other_attributes = other.attributes
    AiHealth::Probe.any_instance.stubs(:llm).returns(mock("passing probe", passing?: true))

    with_self_hosting do
      post configure_provider_settings_ai_prompts_path, as: :json, params: payload.deep_merge(
        family_id: other.family_id,
        ai_configuration: { provider: "openrouter", model: "openai/gpt-4.1-mini", id: other.id, family_id: other.family_id }
      )
      assert_response :success
      assert_equal "openrouter", @user.family.reload.ai_configuration.provider
      assert_equal "openai/gpt-4.1-mini", @user.family.ai_configuration.model
      assert_equal other_attributes, other.reload.attributes
      assert_not_includes response.body, "synthetic-key"
    end
  end

  test "OpenRouter validation failures return useful errors without exposing a key" do
    %w[missing_model invalid_model connection_failed].each do |error|
      configuration = mock("configuration", save: false, error: error)
      OnboardingAiConfiguration.expects(:new).with(
        family: @user.family, provider: "openrouter", api_key: "synthetic-key", model: "invalid-model"
      ).returns(configuration)

      with_self_hosting do
        post configure_provider_settings_ai_prompts_path, as: :json, params: payload.deep_merge(
          ai_configuration: { provider: "openrouter", model: "invalid-model" }
        )
        assert_response :unprocessable_entity
        assert_equal error, response.parsed_body["error"]
        assert_not_includes response.body, "synthetic-key"
      end
    end
  end

  test "managed mode exposes family provider controls to admins alongside prompt editing" do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    get settings_ai_prompts_path
    assert_response :success
    assert_select "[data-controller='onboarding-provider']"
    assert_select "textarea#family_ai_prompt_chat_system"

    configuration = mock("configuration", save: true, provider: "anthropic")
    OnboardingAiConfiguration.expects(:new).with(family: @user.family, provider: "anthropic", api_key: "synthetic-key", model: nil).returns(configuration)
    post configure_provider_settings_ai_prompts_path, as: :json, params: payload
    assert_response :success
  end

  test "managed mode keeps provider configuration away from members" do
    sign_in users(:family_member)
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)

    OnboardingAiConfiguration.expects(:new).never
    post configure_provider_settings_ai_prompts_path, as: :json, params: payload
    assert_response :forbidden
  end

  test "members and guests cannot configure family providers" do
    OnboardingAiConfiguration.expects(:new).never
    with_self_hosting do
      [ users(:family_member), users(:intro_user) ].each do |user|
        sign_in user
        %w[anthropic openrouter].each do |provider|
          post configure_provider_settings_ai_prompts_path, as: :json, params: payload.deep_merge(
            ai_configuration: { provider: provider, model: "openai/gpt-4.1-mini" }
          )
          assert_response :forbidden
        end
      end
    end
  end

  test "admin and super admin cannot target another family with forged identifiers" do
    other = families(:empty).create_ai_configuration!(provider: "openai", api_key: "other-family-key")
    configuration = stub("configuration", save: true, provider: "anthropic")
    OnboardingAiConfiguration.expects(:new).with(family: @user.family, provider: "anthropic", api_key: "synthetic-key", model: "untrusted-model").twice.returns(configuration)

    with_self_hosting do
      %w[admin super_admin].each do |role|
        @user.update!(role: role)
        sign_in @user
        post configure_provider_settings_ai_prompts_path, as: :json, params: payload.deep_merge(
          family_id: other.family_id,
          ai_configuration: { id: other.id, family_id: other.family_id, model: "untrusted-model", endpoint: "https://untrusted.invalid" }
        )
        assert_response :success
        assert_equal({ "status" => "saved", "provider" => "anthropic" }, response.parsed_body)
        assert_not_includes response.body, "synthetic-key"
      end
    end
  end

  test "checked key rotations affect only the current family and preserve assistant preferences" do
    family = @user.family
    family.create_ai_configuration!(provider: "openai", api_key: "original-family-key")
    other = families(:empty).create_ai_configuration!(provider: "openai", api_key: "other-family-key")
    other_attributes = other.attributes
    family_preferences = family.attributes.slice("assistant_type", "ai_prompt_chat_system")
    user_preferences = @user.attributes.slice("ai_enabled", "onboarded_at", "set_onboarding_preferences_at", "onboarding_ai_mode")
    global_settings = Setting.order(:var).pluck(:var, :value)
    AiHealth::Probe.any_instance.stubs(:llm).returns(stub("passing probe", passing?: true))

    with_self_hosting do
      2.times do |attempt|
        key = "rotated-family-key-#{attempt}"
        post configure_provider_settings_ai_prompts_path, as: :json, params: payload.deep_merge(ai_configuration: { api_key: key })
        assert_response :success
        assert_equal "anthropic", family.reload.ai_configuration.provider
        assert_equal key, family.ai_configuration.api_key
        assert_not_includes response.body, key
        assert_equal 1, Family::AiConfiguration.where(family: family).count
        assert_equal other_attributes, other.reload.attributes
        assert_equal family_preferences, family.attributes.slice(*family_preferences.keys)
        assert_equal user_preferences, @user.reload.attributes.slice(*user_preferences.keys)
        assert_equal global_settings, Setting.order(:var).pluck(:var, :value)
      end
    end
  end

  test "a failed key check leaves saved credentials unchanged and returns a safe error" do
    saved = @user.family.create_ai_configuration!(provider: "openai", api_key: "original-family-key")
    saved_attributes = saved.attributes
    AiHealth::Probe.any_instance.stubs(:llm).returns(mock("failed probe", passing?: false))

    with_self_hosting do
      post configure_provider_settings_ai_prompts_path, as: :json, params: payload
      assert_response :unprocessable_entity
      assert_equal({ "status" => "failed", "error" => "connection_failed" }, response.parsed_body)
      assert_not_includes response.body, "synthetic-key"
      assert_equal saved_attributes, saved.reload.attributes
    end
  end

  private
    def payload
      { ai_configuration: { provider: "anthropic", api_key: "synthetic-key" } }
    end
end
