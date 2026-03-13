class MyfundItem::SyncCompleteEvent
  attr_reader :myfund_item

  def initialize(myfund_item)
    @myfund_item = myfund_item
  end

  def broadcast
    myfund_item.family.broadcast_sync_complete
  end
end
