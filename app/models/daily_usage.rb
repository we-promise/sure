# Best-effort daily activity sent to the shared feedback project.
class DailyUsage
  EVENTS = %w[web_ui_served_daily ai_assistant_served_daily job_served_daily mcp_call_served_daily].freeze

  def self.enabled?(event)
    return false unless EVENTS.include?(event)

    config = Rails.configuration.x.posthog
    return false unless Rails.env.production? || (Rails.env.development? && config.development_enabled)
    return false unless config.feedback_enabled && $posthog_feedback

    event != "web_ui_served_daily" || !Rails.cache.is_a?(ActiveSupport::Cache::NullStore)
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
