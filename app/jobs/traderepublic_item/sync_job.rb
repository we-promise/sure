class TraderepublicItem::SyncJob < ApplicationJob
  queue_as :high_priority

  def perform(traderepublic_item)
    Rails.logger.info "TraderepublicItem::SyncJob: Starting sync for item #{traderepublic_item.id}"

    unless traderepublic_item.credentials_configured?
      Rails.logger.error "TraderepublicItem::SyncJob: Item #{traderepublic_item.id} has no credentials"
      return
    end

    unless traderepublic_item.session_configured?
      Rails.logger.error "TraderepublicItem::SyncJob: Item #{traderepublic_item.id} has no session. Login required."
      traderepublic_item.update!(status: :requires_update)
      return
    end

    # Create importer and run sync
    importer = TraderepublicItem::Importer.new(traderepublic_item)
    success = importer.import

    if success
      Rails.logger.info "TraderepublicItem::SyncJob: Sync completed successfully for item #{traderepublic_item.id}"
    else
      Rails.logger.error "TraderepublicItem::SyncJob: Sync failed for item #{traderepublic_item.id}"
    end

    success
  rescue => e
    Rails.logger.error "TraderepublicItem::SyncJob: Unexpected error for item #{traderepublic_item.id} - #{e.class}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    false
  end
end
