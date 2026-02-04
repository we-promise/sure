module Assistant::Provided
  extend ActiveSupport::Concern

  def get_model_provider(ai_model)
    provider = registry.providers.find { |p| p.supports_model?(ai_model) }

    # Handle OpenClaw unavailability with automatic fallback to OpenAI
    if provider.is_a?(Provider::Openclaw) && !provider.available?
      Rails.logger.info("OpenClaw gateway unavailable, falling back to OpenAI")
      fallback_provider = registry.providers.find { |p| p.is_a?(Provider::Openai) }
      return fallback_provider if fallback_provider
    end

    provider
  end

  private
    def registry
      @registry ||= Provider::Registry.for_concept(:llm)
    end
end
