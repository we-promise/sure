class SyncGocardlessScheduledJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  TWICE_WEEKLY_DAYS  = [ 1, 4 ].freeze  # Monday, Thursday
  THRICE_WEEKLY_DAYS = [ 1, 3, 5 ].freeze  # Monday, Wednesday, Friday

  def perform
    today = Date.current.wday

    GocardlessItem.active.find_each do |item|
      next if item.agreement_expired? || item.requires_update?

      should_sync = case item.sync_frequency
                    when "daily"         then daily_sync_due?(item)
                    when "twice_weekly"  then TWICE_WEEKLY_DAYS.include?(today)
                    when "thrice_weekly" then THRICE_WEEKLY_DAYS.include?(today)
                    else false
                    end

      item.sync_later if should_sync
    rescue => e
      Rails.logger.error("SyncGocardlessScheduledJob: failed to queue item #{item.id}: #{e.message}")
    end
  end

  private

    def daily_sync_due?(item)
      item.last_synced_at.nil? || item.last_synced_at < 24.hours.ago
    end
end
