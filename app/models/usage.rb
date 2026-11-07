# Best-effort daily activity sent to the shared feedback project.
class Usage
  EVENTS = %w[web_ui_served_daily ai_assistant_served_daily job_served_daily mcp_call_served_daily].freeze

  def self.enabled?(event)
    return false unless EVENTS.include?(event)
    return false unless feedback_enabled?

    event != "web_ui_served_daily" || !Rails.cache.is_a?(ActiveSupport::Cache::NullStore)
  end

  # A stated preference at first family onboarding, never evidence of AI use.
  # The caller consumes a durable claim with the successful onboarding save.
  def self.capture_onboarding_ai_intent(family_id:, mode:)
    return unless %w[none builtin external].include?(mode) && family_id.present?
    return unless feedback_enabled?

    key = Rails.application.key_generator.generate_key("initial-family-onboarding-ai-intent")
    anonymous_id = OpenSSL::HMAC.hexdigest("SHA256", key, family_id.to_s)
    $posthog_feedback.capture(
      distinct_id: anonymous_id,
      event: "initial_family_ai_mode_selected",
      properties: {
        ai_mode: mode, sure_version: Sure.version.to_s,
        "$process_person_profile" => false, "$geoip_disable" => true
      }
    )
  rescue StandardError => error
    Rails.logger.debug("Onboarding AI intent capture skipped: #{error.class}")
  end

  def self.capture(event, user: nil, date: nil, ip: nil)
    return unless enabled?(event)

    web = event == "web_ui_served_daily"
    return if web && (!user || !date)

    # Preserve the web event's user/family-local identity and the installation
    # events' shared UTC identity, including their existing HMAC salts.
    scope = web ? "daily-web-usage" : "daily-installation-usage"
    identity = web ? "#{user.id}:#{date.iso8601}" : Time.now.utc.to_date.iso8601
    key = Rails.application.key_generator.generate_key(scope)
    daily_id = OpenSSL::HMAC.hexdigest("SHA256", key, identity)

    # Claim before capture: a collector failure consumes the day's attempt.
    # Cache/Redis loss can permit repeats; SDK acceptance is not delivery.
    return unless claim(event, daily_id)

    properties = {
      sure_version: Sure.version.to_s,
      "$process_person_profile" => false,
      "$geoip_disable" => !web
    }
    if web
      properties.merge!(preview_features_enabled: user.preview_features_enabled?, "$ip" => ip)
    end

    $posthog_feedback.capture(distinct_id: daily_id, event: event, properties: properties)
  rescue StandardError => error
    Rails.logger.debug("Daily usage capture skipped: #{error.class}")
  end

  private_class_method def self.feedback_enabled?
    config = Rails.configuration.x.posthog
    (Rails.env.production? || (Rails.env.development? && config.development_enabled)) &&
      config.feedback_enabled && $posthog_feedback.present?
  end

  private_class_method def self.claim(event, daily_id)
    if event == "web_ui_served_daily"
      Rails.cache.write([ "daily-web-usage", daily_id ], true, expires_in: 2.days, unless_exist: true)
    else
      # Sidekiq Redis shares installation claims across web/worker processes,
      # including deployments with process-local Rails caches or Sentinel.
      Sidekiq.redis do |redis|
        redis.call("SET", "daily-installation-usage:#{event}:#{daily_id}", "1", "NX", "EX", 2.days.to_i)
      end
    end
  end
end
