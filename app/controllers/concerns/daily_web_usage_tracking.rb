module DailyWebUsageTracking
  extend ActiveSupport::Concern

  included do
    after_action :capture_daily_web_usage
  end

  private
    def capture_daily_web_usage
      return unless Current.user && request.get? && response.status == 200 && response.media_type == "text/html"
      return if controller_path.start_with?("api/")
      return if request.xhr? || turbo_frame_request?
      return if %w[Purpose Sec-Purpose X-Sec-Purpose].any? { |header| request.headers[header].to_s.match?(/prefetch|prerender/i) }
      return unless helpers.posthog_enabled? && Rails.configuration.x.posthog.try(:api_key).present? && $posthog
      return if Rails.cache.is_a?(ActiveSupport::Cache::NullStore)

      # A daily pseudonym supports counting without sending an account ID or
      # creating a lasting person profile. Resolve the configured family zone
      # after authentication, rather than relying on callback ordering.
      day = Time.current.in_time_zone(resolved_timezone).to_date
      key = Rails.application.key_generator.generate_key("daily-web-usage")
      daily_id = OpenSSL::HMAC.hexdigest("SHA256", key, "#{Current.user.id}:#{day.iso8601}")

      # Atomic in the shared Redis cache: requests from different sessions or
      # web workers share one attempt per user/day. Cache loss can permit repeats.
      return unless Rails.cache.write([ "daily-web-usage", daily_id ], true, expires_in: 2.days, unless_exist: true)

      $posthog.capture(
        distinct_id: daily_id,
        event: "web_ui_served_daily",
        properties: {
          preview_features_enabled: Current.user.preview_features_enabled?,
          sure_version: Sure.version.to_s,
          "$process_person_profile" => false,
          "$geoip_disable" => true
        }
      )
    rescue StandardError => error
      # Analytics is best effort; a cache/SDK failure must not fail the UI.
      Rails.logger.debug("Daily web usage capture skipped: #{error.class}")
    end
end
