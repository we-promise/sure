class SaxoItem::SyncCompleteEvent
  def initialize(item)
    @item = item
  end

  def broadcast
    @item.accounts.each(&:broadcast_sync_complete)
    @item.family.broadcast_sync_complete
  end
end
