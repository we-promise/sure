class MoomooItem::SyncCompleteEvent
  attr_reader :moomoo_item

  def initialize(moomoo_item)
    @moomoo_item = moomoo_item
  end

  def broadcast
    moomoo_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    moomoo_item.family.broadcast_sync_complete
  end
end
