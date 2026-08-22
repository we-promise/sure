# Base class for the Settings-driven Sidekiq::Cron jobs (see AutoSyncScheduler,
# MarketDataScheduler). Handles the shared upsert/remove/error-handling
# boilerplate; subclasses only supply job identity, the relevant Settings,
# and their own local-time -> cron-string strategy via `build_cron`.
class CronScheduler
  class << self
    def sync!
      Rails.logger.info("[#{name}] #{enabled_log_label}=#{enabled?}, time=#{time_setting}")
      if enabled?
        upsert_job
      else
        remove_job
      end
    end

    def upsert_job
      time_str = time_setting || default_time
      timezone_str = timezone_setting || "UTC"

      unless Setting.valid_auto_sync_time?(time_str)
        Rails.logger.error("[#{name}] Invalid time format: #{time_str}, using default #{default_time}")
        time_str = default_time
      end

      hour, minute = time_str.split(":").map(&:to_i)
      timezone = ActiveSupport::TimeZone[timezone_str] || ActiveSupport::TimeZone["UTC"]
      cron = build_cron(hour: hour, minute: minute, timezone: timezone)

      job = Sidekiq::Cron::Job.create(**job_attributes(cron))

      if job.nil? || (job.respond_to?(:valid?) && !job.valid?)
        error_msg = job.respond_to?(:errors) ? job.errors.to_a.join(", ") : "unknown error"
        Rails.logger.error("[#{name}] Failed to create cron job: #{error_msg}")
        raise StandardError, "Failed to create #{schedule_label} schedule: #{error_msg}"
      end

      Rails.logger.info("[#{name}] Created cron job with schedule: #{cron}")
      job
    end

    def remove_job
      Sidekiq::Cron::Job.find(job_name)&.destroy
    end

    private
      # Subclasses must implement all of the below.

      def job_name
        raise NotImplementedError
      end

      def enabled?
        raise NotImplementedError
      end

      def enabled_log_label
        raise NotImplementedError
      end

      def time_setting
        raise NotImplementedError
      end

      def timezone_setting
        raise NotImplementedError
      end

      def default_time
        raise NotImplementedError
      end

      def schedule_label
        raise NotImplementedError
      end

      def job_attributes(cron)
        raise NotImplementedError
      end

      def build_cron(hour:, minute:, timezone:)
        raise NotImplementedError
      end
  end
end
