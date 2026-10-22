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

      DailyUsage.capture(
        "web_ui_served_daily",
        user: Current.user,
        date: Time.current.in_time_zone(resolved_timezone).to_date,
        ip: request.remote_ip
      )
    rescue StandardError => error
      # Resolving request context for analytics must not fail the UI.
      Rails.logger.debug("Daily web usage capture skipped: #{error.class}")
    end
end
