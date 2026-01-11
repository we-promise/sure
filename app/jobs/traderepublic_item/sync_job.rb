class TraderepublicItem::SyncJob < ApplicationJob
  queue_as :high_priority

  def perform(sync)
    Rails.logger.info "TraderepublicItem::SyncJob: Starting sync for item \\#{sync.syncable_id} (Sync ##{sync.id})"
    sync.perform
  end
end
