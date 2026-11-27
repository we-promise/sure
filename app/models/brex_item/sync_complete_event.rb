class BrexItem::SyncCompleteEvent
  attr_reader :brex_item

  def initialize(brex_item)
    @brex_item = brex_item
  end

  def broadcast
    brex_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    brex_item.family.broadcast_sync_complete
  end
end
