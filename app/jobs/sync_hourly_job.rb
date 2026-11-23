class SyncHourlyJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  # Provider item classes that opt-in to hourly syncing
  HOURLY_SYNCABLES = [
    CoinstatsItem # https://coinstats.app/api-docs/rate-limits#plan-limits
  ].freeze

  # Schedule configured providers, including existing wallets outside Preview gating.
  def perform
    Rails.logger.info("Starting hourly sync")
    HOURLY_SYNCABLES.each do |syncable_class|
      sync_items(syncable_class.active)
    end
    sync_items(BitcoinWalletAccount.linked.joins(:onchain_wallet_item).merge(OnchainWalletItem.active))
    Rails.logger.info("Completed hourly sync")
  end

  private

    def sync_items(scope)
      scope.find_each do |item|
        item.sync_later
      rescue => e
        Rails.logger.error("Failed to sync #{item.class.name} #{item.id}: #{e.message}")
      end
    end
end
