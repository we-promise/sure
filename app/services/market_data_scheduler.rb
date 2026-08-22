class MarketDataScheduler < CronScheduler
  JOB_NAME = "import_market_data"

  class << self
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
