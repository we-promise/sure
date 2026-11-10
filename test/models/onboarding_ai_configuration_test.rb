require "test_helper"

class OnboardingAiConfigurationTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @other_family = families(:empty)
    @probe = mock("provider probe")
    AiHealth::Probe.stubs(:new).returns(@probe)
  end

  test "each provider is checked at its official endpoint before the family key is saved" do
    %w[openai anthropic].each do |provider|
      key = "synthetic-#{provider}-test-key"
      endpoint = provider == "openai" ? AiHealth::OPENAI_DEFAULT_ENDPOINT : AiHealth::ANTHROPIC_DEFAULT_ENDPOINT
      model = Family::AiConfiguration.default_model(provider)
      @probe.expects(:llm).with(provider: provider.to_sym, endpoint: endpoint, access_token: key, model: model).returns(stub(passing?: true))
      assert OnboardingAiConfiguration.new(family: @family, provider: provider, api_key: key).save
      configuration = @family.reload.ai_configuration
      assert_equal key, configuration.api_key
      assert_equal provider, configuration.provider
      assert_equal model, configuration.model
      assert_not_includes configuration.encrypted_api_key, key
      assert_nil @other_family.reload.ai_configuration
    end
  end

  test "family configuration ignores and does not change installation credentials endpoints and models" do
    setting_snapshot = Setting.where(var: %w[openai_access_token anthropic_access_token llm_provider]).pluck(:var, :value)
    with_env_overrides(
      "LLM_PROVIDER" => "anthropic", "OPENAI_ACCESS_TOKEN" => "operator-token",
      "OPENAI_URI_BASE" => "https://operator.example/v1", "OPENAI_MODEL" => "local-model",
      "OPENAI_EXTRA_HEADERS" => '{"Authorization":"Bearer operator-secret"}',
      "ANTHROPIC_BASE_URL" => "https://operator.example/anthropic", "ANTHROPIC_MODEL" => "custom-model"
    ) do
      @probe.expects(:llm).with(
        provider: :openai, endpoint: AiHealth::OPENAI_DEFAULT_ENDPOINT,
        access_token: "synthetic-family-key", model: Provider::Openai::DEFAULT_MODEL
      ).returns(stub(passing?: true))

      assert OnboardingAiConfiguration.new(family: @family, provider: "openai", api_key: "synthetic-family-key").save
      assert_equal setting_snapshot, Setting.where(var: %w[openai_access_token anthropic_access_token llm_provider]).pluck(:var, :value)
    end
  end

  test "OpenRouter saves a checked family-selected model without changing another family" do
    @probe.expects(:llm).with(
      provider: :openrouter, endpoint: Provider::Openrouter::ENDPOINT,
      access_token: "synthetic-router-key", model: "openai/gpt-4.1-mini"
    ).returns(stub(passing?: true))

    assert OnboardingAiConfiguration.new(family: @family, provider: "openrouter", api_key: "synthetic-router-key", model: "openai/gpt-4.1-mini").save
    configuration = @family.reload.ai_configuration
    assert_equal "openrouter", configuration.provider
    assert_equal "openai/gpt-4.1-mini", configuration.model
    assert_equal "synthetic-router-key", configuration.api_key
    assert_nil @other_family.reload.ai_configuration
  end

  test "OpenRouter missing or malformed models fail before probing or saving" do
    @probe.expects(:llm).never
    [ [ "", "missing_model" ], [ "https://private.example/model", "invalid_model" ], [ "openai/model\nheader", "invalid_model" ] ].each do |model, error|
      configuration = OnboardingAiConfiguration.new(family: @family, provider: "openrouter", api_key: "synthetic-key", model: model)
      assert_not configuration.save
      assert_equal error, configuration.error
    end
    assert_nil @family.reload.ai_configuration
  end

  test "failed OpenRouter validation preserves the previous provider model and credential" do
    saved = @family.create_ai_configuration!(provider: "openai", api_key: "synthetic-original-key")
    @probe.expects(:llm).returns(stub(passing?: false))
    configuration = OnboardingAiConfiguration.new(family: @family, provider: "openrouter", api_key: "synthetic-invalid-key", model: "openai/gpt-4.1-mini")

    assert_not configuration.save
    assert_equal "connection_failed", configuration.error
    assert_equal "synthetic-original-key", saved.reload.api_key
    assert_equal "openai", saved.provider
    assert_equal Provider::Openai::DEFAULT_MODEL, saved.model
  end

  test "failed checks do not replace the family's saved configuration" do
    saved = @family.create_ai_configuration!(provider: "openai", api_key: "synthetic-original-key")
    @probe.expects(:llm).returns(stub(passing?: false))
    configuration = OnboardingAiConfiguration.new(family: @family, provider: "anthropic", api_key: "synthetic-invalid-key")

    assert_not configuration.save
    assert_equal "connection_failed", configuration.error
    assert_equal "synthetic-original-key", saved.reload.api_key
    assert_equal "openai", saved.provider
  end

  test "invalid provider or empty key never reaches provider or persistence" do
    @probe.expects(:llm).never
    assert_not OnboardingAiConfiguration.new(family: @family, provider: "other", api_key: "synthetic-key").save
    assert_not OnboardingAiConfiguration.new(family: @family, provider: "openai", api_key: " ").save
    assert_not OnboardingAiConfiguration.new(family: @family, provider: "openai", api_key: "bad\nkey").save
    assert_nil @family.reload.ai_configuration
  end

  test "request logging filters the submitted API key and ciphertext" do
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(
      "ai_configuration" => { "provider" => "openai", "api_key" => "synthetic-key", "encrypted_api_key" => "ciphertext" }
    )
    assert_equal "[FILTERED]", filtered.dig("ai_configuration", "api_key")
    assert_equal "[FILTERED]", filtered.dig("ai_configuration", "encrypted_api_key")
  end

  test "a persistence failure returns no exception details and keeps saved credentials" do
    saved = @family.create_ai_configuration!(provider: "openai", api_key: "synthetic-original-key")
    @probe.expects(:llm).returns(stub(passing?: true))
    Family::AiConfiguration.any_instance.expects(:update!).raises(StandardError, "synthetic-private-detail")
    configuration = OnboardingAiConfiguration.new(family: @family, provider: "openai", api_key: "synthetic-replacement-key")

    assert_not configuration.save
    assert_equal "save_failed", configuration.error
    assert_equal "synthetic-original-key", saved.reload.api_key
  end

  test "a later saved family configuration wins over an older successful probe" do
    @probe.expects(:llm).with do
      @family.create_ai_configuration!(provider: "anthropic", api_key: "synthetic-newer-key")
      true
    end.returns(stub(passing?: true))
    configuration = OnboardingAiConfiguration.new(family: @family, provider: "openai", api_key: "synthetic-older-key")

    assert_not configuration.save
    assert_equal "configuration_changed", configuration.error
    assert_equal "synthetic-newer-key", @family.reload.ai_configuration.api_key
    assert_equal "anthropic", @family.ai_configuration.provider
  end

  test "another family's configuration change does not block this family's save" do
    @probe.expects(:llm).with do
      @other_family.create_ai_configuration!(provider: "anthropic", api_key: "synthetic-other-family-key")
      true
    end.returns(stub(passing?: true))

    assert OnboardingAiConfiguration.new(family: @family, provider: "openai", api_key: "synthetic-this-family-key").save
    assert_equal "synthetic-this-family-key", @family.reload.ai_configuration.api_key
    assert_equal "synthetic-other-family-key", @other_family.reload.ai_configuration.api_key
  end

  test "probes are isolated and their debug entries belong to the configuring family" do
    AiHealth::Probe.unstub(:new)
    AiHealth::Probe.expects(:new).with do |options|
      options[:force] && options[:cache].is_a?(ActiveSupport::Cache::NullStore) && options[:family] == @family
    end.returns(@probe)
    @probe.expects(:llm).returns(stub(passing?: true))

    assert OnboardingAiConfiguration.new(family: @family, provider: "openai", api_key: "synthetic-key").save
  end
end
