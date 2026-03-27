module Assistant::Provided
  extend ActiveSupport::Concern

  def get_model_provider(ai_model, family: nil)
    family_provider = family.present? ? Provider::Registry.openai_for_family(family) : nil
    if family_provider&.supports_model?(ai_model)
      return family_provider
    end

    registry.providers.find { |provider| provider.supports_model?(ai_model) }
  end

  private
    def registry
      @registry ||= Provider::Registry.for_concept(:llm)
    end
end
