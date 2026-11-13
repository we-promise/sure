class UpItem::SyncCompleteEvent
  attr_reader :up_item

  # Build the event for the given +up_item+.
  def initialize(up_item)
    @up_item = up_item
  end

  # Broadcast sync-complete Turbo updates for the item, its accounts, and family.
  def broadcast
    up_item.accounts.each(&:broadcast_sync_complete)

    up_item.family.broadcast_sync_complete
  end
end
