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
    sync_due_enable_banking_items if Setting.auto_sync_enabled
    Rails.logger.info("Completed hourly sync")
  end

  private

    def recover_enable_banking_retries
      EnableBankingItem.active.where.not(sync_retry_reason: nil).find_each do |item|
        next unless item.sync_retry_pending? && item.sync_retry_at.present? && item.sync_retry_at <= Time.current

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

    def sync_due_enable_banking_items
      EnableBankingItem.active.where(status: :good).where.not(session_id: nil).find_each do |item|
        next unless item.session_valid? && item.sync_budget_key.present?
        next if item.syncing? || item.sync_retry_pending?
        next unless item.next_background_sync_at.present? && item.next_background_sync_at <= Time.current

        item.sync_later
      rescue => e
        DebugLogEntry.capture(
          category: "provider_sync_retry_enqueue_failed", level: :error,
          message: "Enable Banking background sync could not be enqueued",
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
