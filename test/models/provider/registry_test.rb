require "test_helper"

class Provider::RegistryTest < ActiveSupport::TestCase
  test "providers filters out nil values when provider is not configured" do
    # Ensure OpenAI and Cloudflare are not configured
    ClimateControl.modify("OPENAI_ACCESS_TOKEN" => nil, "CLOUDFLARE_AI_GATEWAY_ACCOUNT_ID" => nil, "CLOUDFLARE_AI_GATEWAY_ID" => nil) do
      Setting.stubs(:openai_access_token).returns(nil)
      Setting.stubs(:cloudflare_ai_gateway_account_id).returns(nil)
      Setting.stubs(:cloudflare_ai_gateway_id).returns(nil)

      registry = Provider::Registry.for_concept(:llm)

      # Should return empty array instead of [nil]
      assert_equal [], registry.providers
    end
  end

  test "providers returns configured providers" do
    # Mock a configured OpenAI provider
    mock_provider = mock("openai_provider")
    Provider::Registry.stubs(:openai).returns(mock_provider)
    Provider::Registry.stubs(:cloudflare_ai_gateway).returns(nil)

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

  test "cloudflare_ai_gateway provider created when configured" do
    ClimateControl.modify(
      "CLOUDFLARE_AI_GATEWAY_ACCOUNT_ID" => "test-account",
      "CLOUDFLARE_AI_GATEWAY_ID" => "test-gateway",
      "CLOUDFLARE_AI_GATEWAY_ACCESS_TOKEN" => "test-token",
      "CLOUDFLARE_AI_GATEWAY_MODEL" => "openai/gpt-4o"
    ) do
      provider = Provider::Registry.get_provider(:cloudflare_ai_gateway)

      assert_not_nil provider
      assert_instance_of Provider::CloudflareAiGateway, provider
    end
  end

  test "cloudflare_ai_gateway returns nil when not configured" do
    ClimateControl.modify(
      "CLOUDFLARE_AI_GATEWAY_ACCOUNT_ID" => nil,
      "CLOUDFLARE_AI_GATEWAY_ID" => nil,
      "CLOUDFLARE_AI_GATEWAY_TOKEN" => nil,
      "CLOUDFLARE_AI_GATEWAY_ACCESS_TOKEN" => nil,
      "CLOUDFLARE_AI_GATEWAY_MODEL" => nil
    ) do
      Setting.stubs(:cloudflare_ai_gateway_account_id).returns(nil)
      Setting.stubs(:cloudflare_ai_gateway_id).returns(nil)

      provider = Provider::Registry.get_provider(:cloudflare_ai_gateway)

      assert_nil provider
    end
  end

  test "cloudflare_ai_gateway returns nil when model is missing" do
    ClimateControl.modify(
      "CLOUDFLARE_AI_GATEWAY_ACCOUNT_ID" => "test-account",
      "CLOUDFLARE_AI_GATEWAY_ID" => "test-gateway",
      "CLOUDFLARE_AI_GATEWAY_ACCESS_TOKEN" => "test-token",
      "CLOUDFLARE_AI_GATEWAY_MODEL" => nil
    ) do
      Setting.stubs(:cloudflare_ai_gateway_model).returns(nil)

      provider = Provider::Registry.get_provider(:cloudflare_ai_gateway)

      assert_nil provider
    end
  end

  test "llm concept includes cloudflare_ai_gateway" do
    registry = Provider::Registry.for_concept(:llm)

    # Use send to access private method for testing
    available = registry.send(:available_providers)
    assert_includes available, :cloudflare_ai_gateway
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
end
