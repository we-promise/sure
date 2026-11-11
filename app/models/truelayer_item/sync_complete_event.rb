class TruelayerItem::SyncCompleteEvent
  attr_reader :truelayer_item

  def initialize(truelayer_item)
    @truelayer_item = truelayer_item
  end

  def broadcast
    # Update UI with latest account data
    truelayer_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    # Let family handle sync notifications
    truelayer_item.family.broadcast_sync_complete
  end
end
