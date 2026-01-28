class AutoSyncScheduler
  JOB_NAME = "sync_all_accounts"

  def self.sync!
    Rails.logger.info("[AutoSyncScheduler] auto_sync_enabled=#{Setting.auto_sync_enabled}, time=#{Setting.auto_sync_time}")
    if Setting.auto_sync_enabled?
      upsert_job
    else
      remove_job
    end
  end

  def self.upsert_job
    time_str = Setting.auto_sync_time || "02:22"
    timezone_str = Setting.auto_sync_timezone || "UTC"

    unless Setting.valid_auto_sync_time?(time_str)
      Rails.logger.error("[AutoSyncScheduler] Invalid time format: #{time_str}, using default 02:22")
      time_str = "02:22"
    end

    hour, minute = time_str.split(":").map(&:to_i)
    timezone = ActiveSupport::TimeZone[timezone_str] || ActiveSupport::TimeZone["UTC"]
    local_time = timezone.now.change(hour: hour, min: minute, sec: 0)
    utc_time = local_time.utc

    cron = "#{utc_time.min} #{utc_time.hour} * * *"

    job = Sidekiq::Cron::Job.create(
      name: JOB_NAME,
      cron: cron,
      class: "SyncAllJob",
      queue: "scheduled",
      description: "Syncs all accounts for all families"
    )

    if job.nil? || (job.respond_to?(:valid?) && !job.valid?)
      error_msg = job.respond_to?(:errors) ? job.errors.to_a.join(", ") : "unknown error"
      Rails.logger.error("[AutoSyncScheduler] Failed to create cron job: #{error_msg}")
      raise StandardError, "Failed to create sync schedule: #{error_msg}"
    end

    Rails.logger.info("[AutoSyncScheduler] Created cron job with schedule: #{cron} (#{time_str} #{timezone_str})")
    job
  end

  def self.remove_job
    if (job = Sidekiq::Cron::Job.find(JOB_NAME))
      job.destroy
    end
  end
end
