class MarketDataScheduler < CronScheduler
  JOB_NAME = "import_market_data"

  class << self
    # Writes a failed schedule sync to the debug log (/settings/debug), so an
    # admin can see why daily price imports stopped without server log access.
    # Never raises: it runs inside rescue blocks (incl. Sidekiq startup), and
    # reading the settings can fail for the same reason the sync failed.
    def capture_sync_failure(error, source:, user: nil)
      DebugLogEntry.capture(
        category: "market_data_schedule",
        level: "error",
        message: "Market data schedule could not be applied",
        source: source,
        user: user,
        metadata: {
          job_name: JOB_NAME,
          time: Setting.market_data_sync_time,
          timezone: Setting.market_data_sync_timezone,
          exception_class: error.class.name,
          exception_message: error.message
        }
      )
    rescue StandardError => e
      Rails.logger.error("[MarketDataScheduler] Failed to write debug log entry: #{e.class}: #{e.message}")
      nil
    end

    private
      def job_name = JOB_NAME
      def enabled? = Setting.market_data_sync_enabled?
      def enabled_log_label = "market_data_sync_enabled"
      def time_setting = Setting.market_data_sync_time
      def timezone_setting = Setting.market_data_sync_timezone
      def default_time = "22:00"
      def schedule_label = "market data sync"

      def job_attributes(cron)
        {
          name: JOB_NAME,
          cron: cron,
          class: "ImportMarketDataJob",
          active_job: true, # see config/schedule.yml
          queue: "scheduled",
          args: { mode: "full", clear_cache: false },
          description: "Imports market data daily (Mon-Fri) at the configured time"
        }
      end

      # Markets are closed on weekends, matching the previous static
      # config/schedule.yml entry ("0 22 * * 1-5"). The IANA timezone is
      # embedded directly in the cron string (sidekiq-cron/fugit syntax)
      # instead of converting to a fixed UTC offset, so the job keeps firing
      # at the configured local time/weekday across daylight-saving
      # transitions rather than drifting by an hour or landing on the wrong
      # local day near the UTC date boundary.
      def build_cron(hour:, minute:, timezone:)
        iana_timezone = timezone.tzinfo.name
        "#{minute} #{hour} * * 1-5 #{iana_timezone}"
      end
  end
end
