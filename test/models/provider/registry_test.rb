require "test_helper"

class Provider::RegistryTest < ActiveSupport::TestCase
  test "providers filters out nil values when provider is not configured" do
    # Ensure neither OpenAI nor Gemini is configured
    ClimateControl.modify("OPENAI_ACCESS_TOKEN" => nil, "GEMINI_API_KEY" => nil) do
      Setting.stubs(:openai_access_token).returns(nil)
      Setting.stubs(:gemini_api_key).returns(nil)

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

  # ---------------------------------------------------------------------------
  # Gemini provider
  # ---------------------------------------------------------------------------

  test "gemini provider returns a Provider::Openai instance using Gemini base URL" do
    ClimateControl.modify("GEMINI_API_KEY" => nil, "GEMINI_MODEL" => nil) do
      Setting.stubs(:gemini_api_key).returns("test-gemini-key")
      Setting.stubs(:gemini_model).returns(nil)

      provider = Provider::Registry.get_provider(:gemini)

      assert_not_nil provider
      assert_instance_of Provider::Openai, provider
      assert provider.custom_provider?, "Gemini provider should report as custom provider"
    end
  end

  test "gemini provider uses configured model from Setting" do
    ClimateControl.modify("GEMINI_API_KEY" => nil, "GEMINI_MODEL" => nil) do
      Setting.stubs(:gemini_api_key).returns("test-gemini-key")
      Setting.stubs(:gemini_model).returns("gemini-2.5-pro")

      provider = Provider::Registry.get_provider(:gemini)

      assert_equal "configured model: gemini-2.5-pro", provider.supported_models_description
    end
  end

  test "gemini provider uses default model when none configured" do
    ClimateControl.modify("GEMINI_API_KEY" => nil, "GEMINI_MODEL" => nil) do
      Setting.stubs(:gemini_api_key).returns("test-gemini-key")
      Setting.stubs(:gemini_model).returns(nil)

      provider = Provider::Registry.get_provider(:gemini)

      assert_equal "configured model: gemini-2.5-flash", provider.supported_models_description
    end
  end

  test "gemini provider returns nil when no API key configured" do
    ClimateControl.modify("GEMINI_API_KEY" => nil) do
      Setting.stubs(:gemini_api_key).returns(nil)

      provider = Provider::Registry.get_provider(:gemini)

      assert_nil provider
    end
  end

  test "openai falls back to gemini when no OpenAI key is set" do
    ClimateControl.modify("OPENAI_ACCESS_TOKEN" => nil, "GEMINI_API_KEY" => nil, "GEMINI_MODEL" => nil) do
      Setting.stubs(:openai_access_token).returns(nil)
      Setting.stubs(:gemini_api_key).returns("test-gemini-key")
      Setting.stubs(:gemini_model).returns(nil)

      provider = Provider::Registry.get_provider(:openai)

      assert_not_nil provider
      assert_instance_of Provider::Openai, provider
      assert provider.custom_provider?, "Fallback Gemini provider should report as custom provider"
    end
  end

  test "openai takes priority over gemini when both are configured" do
    ClimateControl.modify("OPENAI_ACCESS_TOKEN" => nil, "OPENAI_URI_BASE" => nil, "OPENAI_MODEL" => nil,
                          "GEMINI_API_KEY" => nil) do
      Setting.stubs(:openai_access_token).returns("test-openai-key")
      Setting.stubs(:openai_uri_base).returns(nil)
      Setting.stubs(:openai_model).returns(nil)
      Setting.stubs(:gemini_api_key).returns("test-gemini-key")

      provider = Provider::Registry.get_provider(:openai)

      assert_not_nil provider
      assert_equal "OpenAI", provider.provider_name
    end
  end

  # ---------------------------------------------------------------------------

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
end
