class SharesightItem::SyncCompleteEvent
  attr_reader :sharesight_item

  def initialize(sharesight_item)
    @sharesight_item = sharesight_item
  end

  def broadcast
    sharesight_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    sharesight_item.family.broadcast_sync_complete
  end
end
