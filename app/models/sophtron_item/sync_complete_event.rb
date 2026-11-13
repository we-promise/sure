class SophtronItem::SyncCompleteEvent
  attr_reader :sophtron_item

  def initialize(sophtron_item)
    @sophtron_item = sophtron_item
  end

  def broadcast
    # Update UI with latest account data
    sophtron_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    # Let family handle sync notifications
    sophtron_item.family.broadcast_sync_complete
  end
end
