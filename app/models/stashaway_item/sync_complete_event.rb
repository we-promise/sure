class StashawayItem::SyncCompleteEvent
  attr_reader :stashaway_item

  def initialize(stashaway_item)
    @stashaway_item = stashaway_item
  end

  def broadcast
    stashaway_item.accounts.each(&:broadcast_sync_complete)

    stashaway_item.family.broadcast_sync_complete
  end
end
