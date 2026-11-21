class EtoroItem::SyncCompleteEvent
  attr_reader :etoro_item

  def initialize(etoro_item)
    @etoro_item = etoro_item
  end

  def broadcast
    etoro_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    etoro_item.family.broadcast_sync_complete
  end
end
