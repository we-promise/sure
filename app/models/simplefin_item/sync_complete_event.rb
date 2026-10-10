class SimplefinItem::SyncCompleteEvent
  attr_reader :simplefin_item

  def initialize(simplefin_item)
    @simplefin_item = simplefin_item
  end

  def broadcast
    # Update UI with latest account data
    simplefin_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    # Let family handle sync notifications
    simplefin_item.family.broadcast_sync_complete
  end
end
