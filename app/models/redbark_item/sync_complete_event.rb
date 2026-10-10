class RedbarkItem::SyncCompleteEvent
  attr_reader :redbark_item

  def initialize(redbark_item)
    @redbark_item = redbark_item
  end

  def broadcast
    # Update UI with latest account data
    redbark_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    # Let family handle sync notifications
    redbark_item.family.broadcast_sync_complete
  end
end
