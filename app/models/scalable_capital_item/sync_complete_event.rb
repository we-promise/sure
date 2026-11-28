class ScalableCapitalItem::SyncCompleteEvent
  def initialize(item)
    @item = item
  end

  def broadcast
    @item.family.broadcast_sync_complete
  end
end
