class TraderepublicItem::SyncCompleteEvent
  def initialize(traderepublic_item)
    @traderepublic_item = traderepublic_item
  end

  def broadcast
    # Placeholder - add any post-sync broadcasts here if needed
    Rails.logger.info "TraderepublicItem::SyncCompleteEvent - Sync completed for item #{@traderepublic_item.id}"
  end
end
