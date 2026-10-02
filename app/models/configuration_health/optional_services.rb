# frozen_string_literal: true

# Configuration-only checks for optional operator integrations. This class never
# initializes a client, sends a test event, or changes telemetry consent.
class ConfigurationHealth::OptionalServices
  Service = Data.define(:key, :status, :settings, :notes) do
    def tone
      status == :incomplete ? :warning : :neutral
    end
  end

  LANGFUSE_KEYS = %w[LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY].freeze
  STRIPE_KEYS = %w[STRIPE_SECRET_KEY STRIPE_WEBHOOK_SECRET].freeze
  STRIPE_PRICES = %w[STRIPE_MONTHLY_PRICE_ID STRIPE_ANNUAL_PRICE_ID].freeze
  LOGTAIL_KEYS = %w[LOGTAIL_API_KEY LOGTAIL_INGESTING_HOST].freeze

  # Returns only static identifiers and status metadata, never setting values.
  def checks
    [ langfuse, sentry, skylight, stripe, posthog, logtail ]
  end

  def langfuse
    result = environment_service(:langfuse, LANGFUSE_KEYS)
    return result unless result.status == :configured

    config = Langfuse.configuration
    if config.public_key != ENV["LANGFUSE_PUBLIC_KEY"] || config.secret_key != ENV["LANGFUSE_SECRET_KEY"]
      return service(:langfuse, :not_checked, notes: [ :restart_required ])
    end
    result
  end

  def sentry
    config = Sentry.configuration
    unless config&.dsn.present?
      return service(:sentry, :not_checked, notes: [ :restart_required ]) if ENV["SENTRY_DSN"].present?
      return service(:sentry, :not_configured)
    end
    return service(:sentry, :disabled, notes: [ :environment_disabled ]) unless config.enabled_in_current_env?

    service(:sentry, :configured)
  end

  def skylight
    # Match the installed Skylight 6.0.4 Railtie: an explicit case-insensitive
    # "false" disables it; other supplied values override the environment list.
    if ENV["SKYLIGHT_ENABLED"]&.match?(/\Afalse\z/i)
      return service(:skylight, :disabled, notes: [ :explicitly_disabled ])
    end
    if ENV["SKYLIGHT_AUTHENTICATION"].blank?
      return environment_service(:skylight, %w[SKYLIGHT_AUTHENTICATION], intended: ENV["SKYLIGHT_ENABLED"].present?)
    end
    unless skylight_loaded?
      return service(:skylight, :not_checked, notes: [ :skylight_not_loaded ])
    end
    unless ENV.key?("SKYLIGHT_ENABLED") || Array(Rails.application.config.skylight.environments).map(&:to_s).include?(Rails.env.to_s)
      return service(:skylight, :disabled, notes: [ :environment_disabled ])
    end

    service(:skylight, :configured)
  end

  def stripe
    # Self-hosted subscription checkout is disabled, but webhook processing can
    # still use Stripe. Price IDs are required only for the managed checkout UI.
    self_hosted = Rails.application.config.app_mode.self_hosted?
    required = self_hosted ? STRIPE_KEYS : STRIPE_KEYS + STRIPE_PRICES
    notes = self_hosted ? [ :self_hosted_checkout_disabled ] : []
    environment_service(:stripe, required, intended: STRIPE_PRICES.any? { |key| ENV[key].present? }, notes: notes)
  end

  def posthog
    # Use the boot-loaded values also used by the shared head and feedback helper.
    # The server client is not gated by the browser's production/development rule.
    config = Rails.configuration.x.posthog
    status = if config.api_key.blank?
      :not_configured
    elsif config.host.blank?
      :incomplete
    else
      :configured
    end
    browser_enabled = Rails.env.production? || (Rails.env.development? && config.development_enabled)
    notes = browser_enabled ? [] : [ :browser_analytics_disabled ]
    if Rails.application.config.app_mode.self_hosted?
      notes << (browser_enabled && config.feedback_enabled ? :shared_feedback_configured : :shared_feedback_disabled)
    end
    settings = status == :incomplete ? %w[POSTHOG_HOST] : []
    service(:posthog, status, settings: settings, notes: notes)
  end

  def logtail
    result = environment_service(:logtail, LOGTAIL_KEYS)
    return result unless result.status == :configured
    return service(:logtail, :disabled, notes: [ :production_only ]) unless Rails.env.production?

    result
  end

  private
    def service(key, status, settings: [], notes: [])
      Service.new(key: key, status: status, settings: settings, notes: notes)
    end

    def environment_service(key, required, intended: false, notes: [])
      missing = required.select { |name| ENV[name].blank? }
      status = if missing.empty?
        :configured
      elsif missing.length == required.length && !intended
        :not_configured
      else
        :incomplete
      end
      service(key, status, settings: status == :incomplete ? missing : [], notes: notes)
    end

    def skylight_loaded?
      defined?(Skylight) && Rails.application.config.respond_to?(:skylight) && Rails.application.config.skylight.present?
    end
end
