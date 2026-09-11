class TradeRepublicItem::SyncCompleteEvent
  attr_reader :trade_republic_item

  def initialize(trade_republic_item)
    @trade_republic_item = trade_republic_item
  end

  def broadcast
    trade_republic_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    trade_republic_item.broadcast_replace_to(
      trade_republic_item.family,
      target: "trade_republic_item_#{trade_republic_item.id}",
      partial: "trade_republic_items/trade_republic_item",
      locals: { trade_republic_item: trade_republic_item }
    )

    trade_republic_item.family.broadcast_sync_complete
  end
end
