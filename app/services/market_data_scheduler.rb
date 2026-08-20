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
    iana_timezone = timezone.tzinfo.name

    # Markets are closed on weekends, matching the previous static
    # config/schedule.yml entry ("0 22 * * 1-5"). The IANA timezone is
    # embedded directly in the cron string (sidekiq-cron/fugit syntax)
    # instead of converting to a fixed UTC offset, so the job keeps firing
    # at the configured local time/weekday across daylight-saving
    # transitions rather than drifting by an hour or landing on the wrong
    # local day near the UTC date boundary.
    cron = "#{minute} #{hour} * * 1-5 #{iana_timezone}"

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

    Rails.logger.info("[MarketDataScheduler] Created cron job with schedule: #{cron}")
    job
  end

  def self.remove_job
    if (job = Sidekiq::Cron::Job.find(JOB_NAME))
      job.destroy
    end
  end
end
