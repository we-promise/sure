class IndexaCapitalItem::SyncCompleteEvent
  attr_reader :indexa_capital_item

  def initialize(indexa_capital_item)
    @indexa_capital_item = indexa_capital_item
  end

  def broadcast
    indexa_capital_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    indexa_capital_item.family.broadcast_sync_complete
  end
end
