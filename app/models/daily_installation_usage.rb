# Best-effort daily activity, shared by web and Sidekiq processes of an install.
class DailyInstallationUsage
  EVENTS = %w[ai_assistant_served_daily job_served_daily].freeze

  def self.capture(event)
    return unless EVENTS.include?(event)

    config = Rails.configuration.x.posthog
    return unless Rails.env.production? || (Rails.env.development? && config.development_enabled)
    return unless config.feedback_enabled && $posthog_feedback

    # Unlike the user-scoped web event, background activity has no family zone.
    # A daily HMAC of the shared deployment secret avoids a lasting install ID.
    day = Time.now.utc.to_date.iso8601
    key = Rails.application.key_generator.generate_key("daily-installation-usage")
    daily_id = OpenSSL::HMAC.hexdigest("SHA256", key, day)

    # Sidekiq's Redis is shared even when Rails uses a process-local cache, and
    # inherits the existing direct Redis/Sentinel deployment configuration.
    # Claim before capture: failures are not retried within the day. Redis loss
    # can permit duplicates; SDK acceptance is not a delivery guarantee.
    claimed = Sidekiq.redis do |redis|
      redis.call("SET", "daily-installation-usage:#{event}:#{daily_id}", "1", "NX", "EX", 2.days.to_i)
    end
    return unless claimed

    $posthog_feedback.capture(
      distinct_id: daily_id,
      event: event,
      properties: {
        sure_version: Sure.version.to_s,
        "$process_person_profile" => false,
        "$geoip_disable" => true
      }
    )
  rescue StandardError => error
    Rails.logger.debug("Daily installation usage capture skipped: #{error.class}")
  end
end
