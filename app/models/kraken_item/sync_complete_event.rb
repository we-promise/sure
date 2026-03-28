class KrakenItem::SyncCompleteEvent
  attr_reader :kraken_item

  def initialize(kraken_item)
    @kraken_item = kraken_item
  end

  def broadcast
    kraken_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    kraken_item.broadcast_replace_to(
      kraken_item.family,
      target: "kraken_item_#{kraken_item.id}",
      partial: "kraken_items/kraken_item",
      locals: { kraken_item: kraken_item }
    )

    kraken_item.family.broadcast_sync_complete
  end
end
