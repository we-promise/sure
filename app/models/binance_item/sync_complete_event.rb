class BinanceItem::SyncCompleteEvent
  attr_reader :binance_item

  def initialize(binance_item)
    @binance_item = binance_item
  end

  def broadcast
    binance_item.accounts.each(&:broadcast_sync_complete)

    binance_item.broadcast_replace_to(
      binance_item.family,
      target: "binance_item_#{binance_item.id}",
      partial: "binance_items/binance_item",
      locals: { binance_item: binance_item }
    )

    binance_item.family.broadcast_sync_complete
  end
end
