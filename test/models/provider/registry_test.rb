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
    Provider::Registry.stubs(:anthropic).returns(nil)

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

  test "preferred_llm_provider returns nil when no provider is configured" do
    Provider::Registry.stubs(:openai).returns(nil)
    Provider::Registry.stubs(:anthropic).returns(nil)
    Setting.stubs(:llm_provider).returns("openai")

    assert_nil Provider::Registry.preferred_llm_provider
  end

  test "preferred_llm_model returns the selected anthropic model" do
    anthropic = Provider::Anthropic.new("fake-anthropic-key")
    Provider::Registry.stubs(:preferred_llm_provider).returns(anthropic)
    Setting.stubs(:anthropic_model).returns("claude-sonnet-4-5")

    ClimateControl.modify("ANTHROPIC_MODEL" => nil) do
      assert_equal "claude-sonnet-4-5", Provider::Registry.preferred_llm_model
    end
  end

  test "preferred_llm_model returns nil when no llm provider is configured" do
    Provider::Registry.stubs(:preferred_llm_provider).returns(nil)

    assert_nil Provider::Registry.preferred_llm_model
  end
end
