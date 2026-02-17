class Provider::CloudflareAiGateway < Provider::Openai
  # Cloudflare AI Gateway compat endpoint — OpenAI-compatible API that routes
  # to multiple LLM providers (OpenAI, Anthropic, Google, Groq, Mistral, etc.)
  # Models use {provider}/{model} format, e.g. "openai/gpt-4o", "anthropic/claude-4-5-sonnet"
  #
  # Auth modes:
  #   - Pass-through: provider API key sent as Authorization header
  #   - BYOK: keys stored in Cloudflare, cf-aig-authorization header authenticates the gateway

  Error = Class.new(Provider::Error)

  SUPPORTED_PROVIDER_PREFIXES = %w[
    openai/
    anthropic/
    google-ai-studio/
    groq/
    mistral/
    workers-ai/
    cohere/
    deepseek/
    cerebras/
    xai/
    perplexity/
  ].freeze

  def initialize(account_id:, gateway_id:, cf_aig_token: nil, access_token: nil, model: nil)
    uri_base = "https://gateway.ai.cloudflare.com/v1/#{account_id}/#{gateway_id}/compat"

    # Pass-through mode: provider API key as access_token
    # BYOK mode: Cloudflare gateway token authenticates, no provider key needed
    effective_token = access_token.presence || "cf-managed"

    super(effective_token, uri_base: uri_base, model: model)

    # Add Cloudflare gateway auth header for BYOK mode
    if cf_aig_token.present?
      @client.add_headers("cf-aig-authorization" => "Bearer #{cf_aig_token}")
    end
  end

  def supports_model?(model)
    SUPPORTED_PROVIDER_PREFIXES.any? { |prefix| model.start_with?(prefix) }
  end

  def provider_name
    "Cloudflare AI Gateway"
  end

  def supported_models_description
    if @default_model.present?
      "configured model: #{@default_model}"
    else
      "models in {provider}/{model} format (e.g., openai/gpt-4o, anthropic/claude-4-5-sonnet)"
    end
  end

  def custom_provider?
    true
  end
end
