# Checks credentials and model metadata before saving a family's hosted provider.
class OnboardingAiConfiguration
  PROVIDERS = Family::AiConfiguration::PROVIDERS

  attr_reader :provider, :error

  # Family admins may configure their family's own provider key in any app
  # mode. A family configuration is always an explicit override: it never
  # falls back to installation credentials, and on managed installations it
  # replaces the hosted default for that family only.
  def self.allowed_for?(user)
    user&.admin? == true
  end

  def initialize(family:, provider:, api_key:, model: nil)
    @family = family
    @provider = provider.to_s
    @api_key = api_key.to_s.strip
    @model = provider.to_s == "openrouter" ? model.to_s.strip : Family::AiConfiguration.default_model(provider)
  end

  def save
    return fail_with("invalid_provider") unless PROVIDERS.include?(provider)
    return fail_with("missing_key") if @api_key.blank? || @api_key.length > 8192 || @api_key.match?(/[\r\n]/)
    return fail_with("missing_model") if @model.blank?
    return fail_with("invalid_model") if provider == "openrouter" && !Provider::Openrouter.valid_model_id?(@model)

    snapshot = configuration_snapshot
    result = AiHealth::Probe.new(force: true, cache: ActiveSupport::Cache::NullStore.new, family: @family).llm(
      provider: provider.to_sym,
      endpoint: endpoint,
      access_token: @api_key,
      model: @model
    )
    return fail_with("connection_failed") unless result.passing?

    # The family row serializes the first insert as well as later updates. Never
    # hold it during the network check or overwrite a newer successful save.
    @family.with_lock do
      if configuration_snapshot != snapshot
        fail_with("configuration_changed")
      else
        configuration = Family::AiConfiguration.find_or_initialize_by(family: @family)
        configuration.update!(provider: provider, model: @model, api_key: @api_key)
        @family.association(:ai_configuration).reset
        true
      end
    end
  rescue StandardError => exception
    Rails.logger.warn("Onboarding provider configuration failed: #{exception.class}")
    fail_with("save_failed")
  ensure
    @api_key = nil
  end

  private
    def endpoint
      case provider
      when "openai" then AiHealth::OPENAI_DEFAULT_ENDPOINT
      when "anthropic" then AiHealth::ANTHROPIC_DEFAULT_ENDPOINT
      when "openrouter" then Provider::Openrouter::ENDPOINT
      end
    end

    def configuration_snapshot
      Family::AiConfiguration.uncached do
        Family::AiConfiguration.where(family_id: @family.id).pick(:id, :provider, :model, :encrypted_api_key, :updated_at)
      end
    end

    def fail_with(error)
      @error = error
      false
    end
end
