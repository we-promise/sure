class Trading212Item::SyncCompleteEvent
  attr_reader :trading212_item

  def initialize(trading212_item)
    @trading212_item = trading212_item
  end

  def broadcast
    trading212_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    trading212_item.family.broadcast_sync_complete
  end
end
