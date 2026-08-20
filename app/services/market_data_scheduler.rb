class MarketDataScheduler
  JOB_NAME = "import_market_data"

  def self.sync!
    Rails.logger.info("[MarketDataScheduler] market_data_sync_enabled=#{Setting.market_data_sync_enabled}, time=#{Setting.market_data_sync_time}")
    if Setting.market_data_sync_enabled?
      upsert_job
    else
      remove_job
    end
  end

  def self.upsert_job
    time_str = Setting.market_data_sync_time || "22:00"
    timezone_str = Setting.market_data_sync_timezone || "UTC"

    unless Setting.valid_auto_sync_time?(time_str)
      Rails.logger.error("[MarketDataScheduler] Invalid time format: #{time_str}, using default 22:00")
      time_str = "22:00"
    end

    hour, minute = time_str.split(":").map(&:to_i)
    timezone = ActiveSupport::TimeZone[timezone_str] || ActiveSupport::TimeZone["UTC"]
    local_time = timezone.now.change(hour: hour, min: minute, sec: 0)
    utc_time = local_time.utc

    # Markets are closed on weekends, matching the previous static
    # config/schedule.yml entry ("0 22 * * 1-5").
    cron = "#{utc_time.min} #{utc_time.hour} * * 1-5"

    job = Sidekiq::Cron::Job.create(
      name: JOB_NAME,
      cron: cron,
      class: "ImportMarketDataJob",
      queue: "scheduled",
      args: { mode: "full", clear_cache: false },
      description: "Imports market data daily (Mon-Fri) at the configured time"
    )

    if job.nil? || (job.respond_to?(:valid?) && !job.valid?)
      error_msg = job.respond_to?(:errors) ? job.errors.to_a.join(", ") : "unknown error"
      Rails.logger.error("[MarketDataScheduler] Failed to create cron job: #{error_msg}")
      raise StandardError, "Failed to create market data sync schedule: #{error_msg}"
    end

    Rails.logger.info("[MarketDataScheduler] Created cron job with schedule: #{cron} (#{time_str} #{timezone_str})")
    job
  end

  def self.remove_job
    if (job = Sidekiq::Cron::Job.find(JOB_NAME))
      job.destroy
    end
  end
end
