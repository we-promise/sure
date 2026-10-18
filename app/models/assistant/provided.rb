module Assistant::Provided
  extend ActiveSupport::Concern

  def get_model_provider(ai_model)
    Provider::Registry.llm_provider_order.each do |name|
      provider = Provider::Registry.get_provider(name)
      return provider if provider&.supports_model?(ai_model)
    end
    nil
  end

  private
    def registry
      @registry ||= Provider::Registry.for_concept(:llm)
    end
end
