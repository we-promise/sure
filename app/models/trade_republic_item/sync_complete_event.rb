class TradeRepublicItem::SyncCompleteEvent
  attr_reader :trade_republic_item

  def initialize(trade_republic_item)
    @trade_republic_item = trade_republic_item
  end

  def broadcast
    trade_republic_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    trade_republic_item.family.broadcast_sync_complete
  end
end
