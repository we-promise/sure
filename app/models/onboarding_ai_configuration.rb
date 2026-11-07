require "yaml"

# Configures the supported hosted providers without accepting a destination URL.
# Custom endpoints and environment-managed settings remain in Hosting settings.
class OnboardingAiConfiguration
  PROVIDERS = %w[openai anthropic].freeze
  CONFIGURATION_KEYS = %w[
    openai_access_token openai_uri_base openai_model
    anthropic_access_token anthropic_base_url anthropic_model llm_provider
  ].freeze

  attr_reader :provider, :error

  def self.allowed_for?(user)
    Rails.application.config.app_mode.self_hosted? && user.manages_instance_settings?
  end

  def self.configuration_locked?(provider, snapshot: configuration_snapshot)
    return true unless PROVIDERS.include?(provider)
    return true if ENV["LLM_PROVIDER"].present?

    if provider == "openai"
      ENV["OPENAI_ACCESS_TOKEN"].present? || ENV["OPENAI_URI_BASE"].present? || setting_value(snapshot, "openai_uri_base").present?
    else
      ENV["ANTHROPIC_ACCESS_TOKEN"].present? || ENV["ANTHROPIC_API_KEY"].present? ||
        ENV["ANTHROPIC_BASE_URL"].present? || setting_value(snapshot, "anthropic_base_url").present?
    end
  end

  def self.configuration_snapshot
    # Bypass both RailsSettings request/shared caches and ActiveRecord query cache.
    Setting.uncached do
      Setting.where(var: CONFIGURATION_KEYS).order(:var).pluck(:var, :value, :updated_at)
    end
  end

  def self.setting_value(snapshot, key)
    raw = snapshot.find { |row| row.first == key }&.second
    return if raw.nil?

    value = YAML.safe_load(raw, permitted_classes: [], aliases: false)
    raise TypeError, "Expected a string setting" unless value.nil? || value.is_a?(String)
    value
  end

  def initialize(provider:, api_key:)
    @provider = provider.to_s
    @api_key = api_key.to_s.strip
  end

  def save
    return fail_with("invalid_provider") unless PROVIDERS.include?(provider)
    return fail_with("missing_key") if @api_key.blank? || @api_key.length > 8192 || @api_key.match?(/[\r\n]/)
    snapshot = self.class.configuration_snapshot
    return fail_with("configuration_locked") if self.class.configuration_locked?(provider, snapshot: snapshot)
    model = effective_model(snapshot)

    result = AiHealth::Probe.new(force: true, cache: ActiveSupport::Cache::NullStore.new).llm(
      provider: provider.to_sym,
      endpoint: provider == "openai" ? AiHealth::OPENAI_DEFAULT_ENDPOINT : AiHealth::ANTHROPIC_DEFAULT_ENDPOINT,
      access_token: @api_key,
      model: model
    )
    return fail_with("connection_failed") unless result.passing?
    Setting.transaction do
      # A brief table write lock also covers absent settings rows and Hosting
      # writers. Never hold it during the network probe. An older successful
      # probe must not overwrite settings saved while it was in flight.
      Setting.connection.execute("LOCK TABLE #{Setting.quoted_table_name} IN SHARE ROW EXCLUSIVE MODE")
      current = self.class.configuration_snapshot
      if current != snapshot || effective_model(current) != model || self.class.configuration_locked?(provider, snapshot: current)
        fail_with("configuration_changed")
      else
        Setting.public_send("#{provider}_access_token=", @api_key)
        Setting.llm_provider = provider
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
    def effective_model(snapshot)
      configured = ENV["#{provider.upcase}_MODEL"].presence || self.class.setting_value(snapshot, "#{provider}_model").presence
      configured || (provider == "openai" ? Provider::Openai::DEFAULT_MODEL : Provider::Anthropic::DEFAULT_MODEL)
    end

    def fail_with(error)
      @error = error
      false
    end
end
