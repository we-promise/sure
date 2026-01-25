class SnaptradeItem::SyncCompleteEvent
  attr_reader :snaptrade_item

  def initialize(snaptrade_item)
    @snaptrade_item = snaptrade_item
  end

  def broadcast
    # Update UI with latest account data
    snaptrade_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    # Update the SnapTrade item view
    snaptrade_item.broadcast_replace_to(
      snaptrade_item.family,
      target: "snaptrade_item_#{snaptrade_item.id}",
      partial: "snaptrade_items/snaptrade_item",
      locals: { snaptrade_item: snaptrade_item }
    )

    # Let family handle sync notifications
    snaptrade_item.family.broadcast_sync_complete
  end
end
