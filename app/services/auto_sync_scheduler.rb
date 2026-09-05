class AutoSyncScheduler < CronScheduler
  JOB_NAME = "sync_all_accounts"

  class << self
    private
      def job_name = JOB_NAME
      def enabled? = Setting.auto_sync_enabled?
      def enabled_log_label = "auto_sync_enabled"
      def time_setting = Setting.auto_sync_time
      def timezone_setting = Setting.auto_sync_timezone
      def default_time = "02:22"
      def schedule_label = "sync"

      def job_attributes(cron)
        {
          name: JOB_NAME,
          cron: cron,
          class: "SyncAllJob",
          queue: "scheduled",
          description: "Syncs all accounts for all families"
        }
      end

      # Converts the configured local time to a fixed UTC offset for the cron
      # string (unlike MarketDataScheduler, which embeds the IANA timezone
      # directly — see that class for why).
      def build_cron(hour:, minute:, timezone:)
        local_time = timezone.now.change(hour: hour, min: minute, sec: 0)
        utc_time = local_time.utc
        "#{utc_time.min} #{utc_time.hour} * * *"
      end
  end
end
