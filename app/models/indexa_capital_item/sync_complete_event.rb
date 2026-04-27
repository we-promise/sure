class IndexaCapitalItem::SyncCompleteEvent
  attr_reader :indexa_capital_item

  def initialize(indexa_capital_item)
    @indexa_capital_item = indexa_capital_item
  end

  def broadcast
    indexa_capital_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    indexa_capital_item.broadcast_replace_to(
      indexa_capital_item.family,
      target: "indexa_capital_item_#{indexa_capital_item.id}",
      partial: "indexa_capital_items/indexa_capital_item",
      locals: { indexa_capital_item: indexa_capital_item }
    )

    indexa_capital_item.family.broadcast_sync_complete
  end
end
