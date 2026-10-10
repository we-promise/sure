class MercuryItem::SyncCompleteEvent
  attr_reader :mercury_item

  def initialize(mercury_item)
    @mercury_item = mercury_item
  end

  def broadcast
    # Update UI with latest account data
    mercury_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    # Let family handle sync notifications
    mercury_item.family.broadcast_sync_complete
  end
end
