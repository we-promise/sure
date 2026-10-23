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
          active_job: true, # see config/schedule.yml
          queue: "scheduled",
          description: "Syncs all accounts for all families"
        }
      end

      # Embeds the IANA timezone in the cron string, like MarketDataScheduler,
      # so the job keeps the configured local time across daylight saving.
      def build_cron(hour:, minute:, timezone:)
        "#{minute} #{hour} * * * #{timezone.tzinfo.name}"
      end
  end
end
