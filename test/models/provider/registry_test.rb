require "test_helper"

class Provider::RegistryTest < ActiveSupport::TestCase
  test "providers filters out nil values when provider is not configured" do
    # Ensure no LLM provider is configured
    ClimateControl.modify(
      "OPENAI_ACCESS_TOKEN" => nil,
      "ANTHROPIC_ACCESS_TOKEN" => nil,
      "ANTHROPIC_API_KEY" => nil
    ) do
      Setting.stubs(:openai_access_token).returns(nil)
      Setting.stubs(:anthropic_access_token).returns(nil)

      registry = Provider::Registry.for_concept(:llm)

      # Should return empty array instead of [nil]
      assert_equal [], registry.providers
    end
  end

  test "providers returns configured providers" do
    # Mock a configured OpenAI provider
    mock_provider = mock("openai_provider")
    Provider::Registry.stubs(:openai).returns(mock_provider)

    registry = Provider::Registry.for_concept(:llm)

    assert_equal [ mock_provider ], registry.providers
  end

  test "get_provider raises error when provider not found for concept" do
    registry = Provider::Registry.for_concept(:llm)

    error = assert_raises(Provider::Registry::Error) do
      registry.get_provider(:nonexistent)
    end

    assert_match(/Provider 'nonexistent' not found for concept: llm/, error.message)
  end

  test "get_provider returns nil when provider not configured" do
    # Ensure OpenAI is not configured
    ClimateControl.modify("OPENAI_ACCESS_TOKEN" => nil) do
      Setting.stubs(:openai_access_token).returns(nil)

      registry = Provider::Registry.for_concept(:llm)

      # Should return nil when provider method exists but returns nil
      assert_nil registry.get_provider(:openai)
    end
  end

  test "anthropic provider returns nil when no credentials are configured" do
    ClimateControl.modify(
      "ANTHROPIC_ACCESS_TOKEN" => nil,
      "ANTHROPIC_API_KEY" => nil
    ) do
      Setting.stubs(:anthropic_access_token).returns(nil)

      assert_nil Provider::Registry.get_provider(:anthropic)
    end
  end

  test "anthropic provider initializes from ANTHROPIC_API_KEY env" do
    ClimateControl.modify("ANTHROPIC_API_KEY" => "fake-anthropic-key-for-tests", "ANTHROPIC_ACCESS_TOKEN" => nil) do
      Setting.stubs(:anthropic_access_token).returns(nil)

      provider = Provider::Registry.get_provider(:anthropic)

      assert_instance_of Provider::Anthropic, provider
    end
  end

  test "anthropic provider falls back to Setting when ENV is empty" do
    ClimateControl.modify(
      "ANTHROPIC_ACCESS_TOKEN" => "",
      "ANTHROPIC_API_KEY" => "",
      "ANTHROPIC_BASE_URL" => "",
      "ANTHROPIC_MODEL" => ""
    ) do
      Setting.stubs(:anthropic_access_token).returns("fake-anthropic-key-from-setting")
      Setting.stubs(:anthropic_base_url).returns(nil)
      Setting.stubs(:anthropic_model).returns(nil)

      provider = Provider::Registry.get_provider(:anthropic)

      assert_instance_of Provider::Anthropic, provider
    end
  end

  test "openai provider falls back to Setting when ENV is empty string" do
    # Mock ENV to return empty string (common in Docker/env files)
    # Use stub_env helper which properly stubs ENV access
    ClimateControl.modify(
      "OPENAI_ACCESS_TOKEN" => "",
      "OPENAI_URI_BASE" => "",
      "OPENAI_MODEL" => ""
    ) do
      Setting.stubs(:openai_access_token).returns("test-token-from-setting")
      Setting.stubs(:openai_uri_base).returns(nil)
      Setting.stubs(:openai_model).returns(nil)

      provider = Provider::Registry.get_provider(:openai)

      # Should successfully create provider using Setting value
      assert_not_nil provider
      assert_instance_of Provider::Openai, provider
    end
  end

  test "preferred_llm_provider returns openai by default" do
    openai = mock("openai")
    Provider::Registry.stubs(:openai).returns(openai)
    Provider::Registry.stubs(:anthropic).returns(mock("anthropic"))
    Setting.stubs(:llm_provider).returns("openai")

    assert_same openai, Provider::Registry.preferred_llm_provider
  end

  test "preferred_llm_provider returns anthropic when selected" do
    anthropic = mock("anthropic")
    Provider::Registry.stubs(:openai).returns(mock("openai"))
    Provider::Registry.stubs(:anthropic).returns(anthropic)
    Setting.stubs(:llm_provider).returns("anthropic")

    assert_same anthropic, Provider::Registry.preferred_llm_provider
  end

  test "preferred_llm_provider falls back to the configured provider when the selected one is unconfigured" do
    openai = mock("openai")
    Provider::Registry.stubs(:openai).returns(openai)
    Provider::Registry.stubs(:anthropic).returns(nil)
    Setting.stubs(:llm_provider).returns("anthropic")

    assert_same openai, Provider::Registry.preferred_llm_provider
  end

  test "preferred_llm_provider follows LLM_PROVIDER over a stored choice" do
    original = Setting.raw_llm_provider
    Setting.llm_provider = "openai"
    anthropic = mock("anthropic")
    Provider::Registry.stubs(:openai).returns(mock("openai"))
    Provider::Registry.stubs(:anthropic).returns(anthropic)

    with_env_overrides("LLM_PROVIDER" => "anthropic") do
      assert_same anthropic, Provider::Registry.preferred_llm_provider
    end
  ensure
    Setting.llm_provider = original
  end

  test "preferred_llm_provider returns nil when no provider is configured" do
    Provider::Registry.stubs(:openai).returns(nil)
    Provider::Registry.stubs(:anthropic).returns(nil)
    Setting.stubs(:llm_provider).returns("openai")

    assert_nil Provider::Registry.preferred_llm_provider
  end

  test "family provider selection is isolated from other families and installation defaults" do
    family = families(:dylan_family)
    other_family = families(:empty)
    family.create_ai_configuration!(provider: "anthropic", api_key: "synthetic-family-a-key")
    other_family.create_ai_configuration!(provider: "openai", api_key: "synthetic-family-b-key")
    family_provider = mock("family A provider")
    other_provider = mock("family B provider")
    Provider::Anthropic.expects(:new).with(
      "synthetic-family-a-key", model: Provider::Anthropic::DEFAULT_MODEL, use_global_settings: false
    ).returns(family_provider)
    Provider::Openai.expects(:new).with(
      "synthetic-family-b-key", model: Provider::Openai::DEFAULT_MODEL, use_global_settings: false
    ).returns(other_provider)
    Provider::Registry.expects(:openai).never
    Provider::Registry.expects(:anthropic).never

    assert_same family_provider, Provider::Registry.preferred_llm_provider(family: family)
    assert_same other_provider, Provider::Registry.get_provider(:openai, family: other_family)
    assert_nil Provider::Registry.get_provider(:openai, family: family)
    assert_equal [ :anthropic ], Provider::Registry.llm_provider_order(family: family)
    assert_equal Provider::Anthropic::DEFAULT_MODEL, Provider::Registry.default_llm_model(family: family)
  end

  test "families without an override retain installation provider fallback" do
    family = families(:dylan_family)
    openai = mock("installation provider")
    Provider::Registry.stubs(:openai).returns(openai)
    Provider::Registry.stubs(:anthropic).returns(nil)
    Setting.stubs(:llm_provider).returns("anthropic")

    assert_same openai, Provider::Registry.preferred_llm_provider(family: family)
    assert_same openai, Provider::Registry.get_provider(:openai, family: family)
  end

  test "an unreadable family override does not fall back to global or alternate providers" do
    family = families(:dylan_family)
    configuration = family.create_ai_configuration!(provider: "anthropic", api_key: "synthetic-key")
    configuration.update_column(:encrypted_api_key, "corrupt-ciphertext")
    Provider::Registry.expects(:openai).never
    Provider::Registry.expects(:anthropic).never

    assert_nil Provider::Registry.preferred_llm_provider(family: family)
    assert_nil Provider::Registry.get_provider(:openai, family: family)
    assert_equal [], Provider::Registry.for_concept(:llm, family: family).providers
    assert_equal Provider::Anthropic::DEFAULT_MODEL, Provider::Registry.default_llm_model(family: family)
  end

  test "concept registries preserve the family for individual and available providers" do
    family = families(:dylan_family)
    family.create_ai_configuration!(provider: "anthropic", api_key: "synthetic-key")
    provider = mock("family provider")
    Provider::Anthropic.stubs(:new).with(
      "synthetic-key", model: Provider::Anthropic::DEFAULT_MODEL, use_global_settings: false
    ).returns(provider)
    registry = Provider::Registry.for_concept(:llm, family: family)

    assert_equal [ provider ], registry.providers
    assert_same provider, registry.get_provider(:anthropic)
    assert_nil registry.get_provider(:openai)
  end

  test "OpenRouter belongs only to the explicitly configured family" do
    family = families(:dylan_family)
    family.create_ai_configuration!(provider: "openrouter", model: "openai/gpt-4.1-mini", api_key: "synthetic-router-key")
    Provider::Registry.expects(:openai).never
    Provider::Registry.expects(:anthropic).never
    registry = Provider::Registry.for_concept(:llm, family: family)

    assert_equal [ Provider::Openrouter ], registry.providers.map(&:class)
    assert_instance_of Provider::Openrouter, registry.get_provider(:openrouter)
    assert_nil registry.get_provider(:openai)
    assert_nil registry.get_provider(:anthropic)
    assert_nil Provider::Registry.get_provider(:openrouter, family: families(:empty))
    assert_equal [ :openrouter ], Provider::Registry.llm_provider_order(family: family)
    assert_equal "openai/gpt-4.1-mini", Provider::Registry.default_llm_model(family: family)
    assert_equal %i[openai anthropic], Provider::Registry.for_concept(:llm).provider_keys
  end

  test "an unreadable OpenRouter credential never falls back to global providers" do
    family = families(:dylan_family)
    family.create_ai_configuration!(provider: "openrouter", model: "openai/gpt-4.1-mini", api_key: "synthetic-key")
    family.ai_configuration.update_column(:encrypted_api_key, "corrupt-ciphertext")
    Provider::Registry.expects(:openai).never
    Provider::Registry.expects(:anthropic).never

    assert_nil Provider::Registry.preferred_llm_provider(family: family)
    assert_equal [], Provider::Registry.for_concept(:llm, family: family).providers
  end
end
