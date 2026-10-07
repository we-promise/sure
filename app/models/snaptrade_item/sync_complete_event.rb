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

    # Let family handle sync notifications
    snaptrade_item.family.broadcast_sync_complete
  end
end
