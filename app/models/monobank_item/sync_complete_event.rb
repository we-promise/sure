class MonobankItem::SyncCompleteEvent
  attr_reader :monobank_item

  # Build the event for the given +monobank_item+.
  def initialize(monobank_item)
    @monobank_item = monobank_item
  end

  # Broadcast sync-complete Turbo updates for the item, its accounts, and family.
  def broadcast
    monobank_item.accounts.each(&:broadcast_sync_complete)

    monobank_item.family.broadcast_sync_complete
  end
end
