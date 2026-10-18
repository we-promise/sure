class SyncHourlyJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  # Provider item classes that opt-in to hourly syncing
  HOURLY_SYNCABLES = [
    CoinstatsItem # https://coinstats.app/api-docs/rate-limits#plan-limits
  ].freeze

  def perform
    Rails.logger.info("Starting hourly sync")
    HOURLY_SYNCABLES.each do |syncable_class|
      sync_items(syncable_class)
    end
    recover_enable_banking_retries
    Rails.logger.info("Completed hourly sync")
  end

  private

    def recover_enable_banking_retries
      EnableBankingItem.active.where.not(sync_retry_reason: nil).where("next_sync_at <= ?", Time.current).find_each do |item|
        item.sync_later unless item.needs_authorization?
      rescue => e
        DebugLogEntry.capture(
          category: "provider_sync_retry_enqueue_failed", level: :error,
          message: "Enable Banking retry recovery could not enqueue a sync",
          source: "SyncHourlyJob", provider_key: "enable_banking", family: item.family,
          metadata: { enable_banking_item_id: item.id, error_class: e.class.name }
        )
      end
    end

    def sync_items(syncable_class)
      syncable_class.active.find_each do |item|
        item.sync_later
      rescue => e
        Rails.logger.error("Failed to sync #{syncable_class.name} #{item.id}: #{e.message}")
      end
    end
end
