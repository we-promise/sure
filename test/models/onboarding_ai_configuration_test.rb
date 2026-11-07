require "test_helper"

class OnboardingAiConfigurationTest < ActiveSupport::TestCase
  ENV_KEYS = %w[LLM_PROVIDER OPENAI_ACCESS_TOKEN OPENAI_URI_BASE ANTHROPIC_ACCESS_TOKEN ANTHROPIC_API_KEY ANTHROPIC_BASE_URL].freeze

  setup do
    @settings = OnboardingAiConfiguration::CONFIGURATION_KEYS.index_with { |key| Setting.public_send(key) }
    Setting.openai_uri_base = nil
    Setting.anthropic_base_url = nil
    @probe = mock("provider probe")
    AiHealth::Probe.stubs(:new).returns(@probe)
  end

  teardown do
    @settings.each { |key, value| Setting.public_send("#{key}=", value) }
  end

  test "each provider is checked at its official endpoint before its encrypted key is saved" do
    with_env_overrides(ENV_KEYS.index_with { nil }) do
      %w[openai anthropic].each do |provider|
        key = "synthetic-#{provider}-test-key"
        endpoint = provider == "openai" ? AiHealth::OPENAI_DEFAULT_ENDPOINT : AiHealth::ANTHROPIC_DEFAULT_ENDPOINT
        model = provider == "openai" ? Provider::Openai.effective_model : Provider::Anthropic.effective_model
        @probe.expects(:llm).with(provider: provider.to_sym, endpoint: endpoint, access_token: key, model: model).returns(stub(passing?: true))
        assert OnboardingAiConfiguration.new(provider: provider, api_key: key).save
        assert_equal key, Setting.public_send("#{provider}_access_token")
        assert_equal provider, Setting.llm_provider
        assert_not_includes Setting.find_by!(var: "#{provider}_access_token").value.to_s, key
      end
    end
  end

  test "failed checks do not replace saved credentials or provider selection" do
    with_env_overrides(ENV_KEYS.index_with { nil }) do
      @probe.expects(:llm).returns(stub(passing?: false))
      configuration = OnboardingAiConfiguration.new(provider: "anthropic", api_key: "synthetic-invalid-key")
      assert_not configuration.save
      assert_equal "connection_failed", configuration.error
      %w[openai_access_token anthropic_access_token llm_provider].each do |key|
        assert_equal @settings[key], Setting.public_send(key)
      end
    end
  end

  test "custom endpoints and environment overrides reject before any key is sent" do
    @probe.expects(:llm).never
    with_env_overrides(ENV_KEYS.index_with { nil }) do
      Setting.openai_uri_base = "https://custom.example/v1"
      configuration = OnboardingAiConfiguration.new(provider: "openai", api_key: "synthetic-key")
      assert_not configuration.save
      assert_equal "configuration_locked", configuration.error
      Setting.openai_uri_base = nil
      ENV_KEYS.each do |env_key|
        with_env_overrides(env_key => "operator-managed") do
          provider = env_key.start_with?("ANTHROPIC") ? "anthropic" : "openai"
          configuration = OnboardingAiConfiguration.new(provider: provider, api_key: "synthetic-key")
          assert_not configuration.save
          assert_equal "configuration_locked", configuration.error
        end
      end
    end
  end

  test "invalid provider or empty key never reaches provider or settings" do
    @probe.expects(:llm).never
    assert_not OnboardingAiConfiguration.new(provider: "other", api_key: "synthetic-key").save
    assert_not OnboardingAiConfiguration.new(provider: "openai", api_key: " ").save
    assert_not OnboardingAiConfiguration.new(provider: "openai", api_key: "bad\nkey").save
  end

  test "request logging filters the submitted API key" do
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(
      "ai_configuration" => { "provider" => "openai", "api_key" => "synthetic-key" }
    )
    assert_equal "[FILTERED]", filtered.dig("ai_configuration", "api_key")
  end

  test "a settings failure rolls back the key and returns no exception details" do
    with_env_overrides(ENV_KEYS.index_with { nil }) do
      @probe.expects(:llm).returns(stub(passing?: true))
      Setting.expects(:llm_provider=).with("openai").raises(StandardError, "synthetic-private-detail")
      configuration = OnboardingAiConfiguration.new(provider: "openai", api_key: "synthetic-replacement-key")
      assert_not configuration.save
      assert_equal "save_failed", configuration.error
      assert_equal @settings["openai_access_token"], Setting.openai_access_token
    end
  ensure
    Setting.unstub(:llm_provider=)
  end

  test "a later saved configuration wins over an older successful probe" do
    with_env_overrides(ENV_KEYS.index_with { nil }) do
      @probe.expects(:llm).with do
        Setting.anthropic_access_token = "synthetic-newer-key"
        Setting.llm_provider = "anthropic"
        true
      end.returns(stub(passing?: true))

      configuration = OnboardingAiConfiguration.new(provider: "openai", api_key: "synthetic-older-key")
      assert_not configuration.save
      assert_equal "configuration_changed", configuration.error
      assert_equal "synthetic-newer-key", Setting.anthropic_access_token
      assert_equal "anthropic", Setting.llm_provider
      assert_equal @settings["openai_access_token"], Setting.openai_access_token
    end
  end

  test "uncached endpoint changes during the probe prevent saving the key" do
    with_env_overrides(ENV_KEYS.index_with { nil }) do
      Setting.openai_uri_base # Populate the normal settings cache with nil.
      @probe.expects(:llm).with do
        Setting.find_by!(var: "openai_uri_base").update_columns(value: "https://custom.example/v1".to_yaml)
        true
      end.returns(stub(passing?: true))

      configuration = OnboardingAiConfiguration.new(provider: "openai", api_key: "synthetic-older-key")
      assert_not configuration.save
      assert_equal "configuration_changed", configuration.error
      assert_equal @settings["openai_access_token"], Setting.openai_access_token
    end
  end

  test "security checks do not trust a stale request settings cache" do
    with_env_overrides(ENV_KEYS.index_with { nil }) do
      Setting.openai_uri_base
      Setting.find_by!(var: "openai_uri_base").update_columns(value: "https://custom.example/v1".to_yaml)
      @probe.expects(:llm).never
      configuration = OnboardingAiConfiguration.new(provider: "openai", api_key: "synthetic-key")
      assert_not configuration.save
      assert_equal "configuration_locked", configuration.error
    end
  end
end
