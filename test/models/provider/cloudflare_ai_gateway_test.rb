require "test_helper"

class Provider::CloudflareAiGatewayTest < ActiveSupport::TestCase
  test "supports_model? matches provider/model format" do
    provider = Provider::CloudflareAiGateway.new(
      account_id: "test-account",
      gateway_id: "test-gateway",
      access_token: "test-token",
      model: "openai/gpt-4o"
    )

    assert provider.supports_model?("openai/gpt-4o")
    assert provider.supports_model?("anthropic/claude-4-5-sonnet")
    assert provider.supports_model?("google-ai-studio/gemini-2.5-pro")
    assert provider.supports_model?("groq/llama-3.1-70b")
    assert provider.supports_model?("mistral/mistral-large")
    assert provider.supports_model?("workers-ai/llama-3.1-8b")
    assert provider.supports_model?("deepseek/deepseek-chat")
    assert provider.supports_model?("xai/grok-2")
    assert provider.supports_model?("perplexity/sonar-pro")
  end

  test "supports_model? rejects bare model names" do
    provider = Provider::CloudflareAiGateway.new(
      account_id: "test-account",
      gateway_id: "test-gateway",
      access_token: "test-token",
      model: "openai/gpt-4o"
    )

    refute provider.supports_model?("gpt-4o")
    refute provider.supports_model?("gpt-4.1")
    refute provider.supports_model?("claude-4-5-sonnet")
    refute provider.supports_model?("unknown-format")
  end

  test "provider_name returns Cloudflare AI Gateway" do
    provider = Provider::CloudflareAiGateway.new(
      account_id: "test-account",
      gateway_id: "test-gateway",
      access_token: "test-token",
      model: "openai/gpt-4o"
    )

    assert_equal "Cloudflare AI Gateway", provider.provider_name
  end

  test "custom_provider? is always true" do
    provider = Provider::CloudflareAiGateway.new(
      account_id: "test-account",
      gateway_id: "test-gateway",
      access_token: "test-token",
      model: "openai/gpt-4o"
    )

    assert provider.custom_provider?
  end

  test "supported_models_description shows configured model" do
    provider = Provider::CloudflareAiGateway.new(
      account_id: "test-account",
      gateway_id: "test-gateway",
      access_token: "test-token",
      model: "openai/gpt-4o"
    )

    assert_equal "configured model: openai/gpt-4o", provider.supported_models_description
  end

  test "works with cf_aig_token for BYOK mode" do
    provider = Provider::CloudflareAiGateway.new(
      account_id: "test-account",
      gateway_id: "test-gateway",
      cf_aig_token: "cf-token-123",
      model: "anthropic/claude-4-5-sonnet"
    )

    assert_equal "Cloudflare AI Gateway", provider.provider_name
    assert provider.supports_model?("anthropic/claude-4-5-sonnet")
  end

  test "works with both tokens for combined auth" do
    provider = Provider::CloudflareAiGateway.new(
      account_id: "test-account",
      gateway_id: "test-gateway",
      cf_aig_token: "cf-token-123",
      access_token: "provider-key-456",
      model: "openai/gpt-4o"
    )

    assert_equal "Cloudflare AI Gateway", provider.provider_name
  end
end
