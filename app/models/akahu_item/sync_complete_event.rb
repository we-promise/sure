class AkahuItem::SyncCompleteEvent
  attr_reader :akahu_item

  def initialize(akahu_item)
    @akahu_item = akahu_item
  end

  def broadcast
    akahu_item.accounts.each(&:broadcast_sync_complete)

    akahu_item.family.broadcast_sync_complete
  end
end
