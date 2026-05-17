class IbkrItem::SyncCompleteEvent
  attr_reader :ibkr_item

  def initialize(ibkr_item)
    @ibkr_item = ibkr_item
  end

  def broadcast
    ibkr_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    ibkr_item.broadcast_replace_to(
      ibkr_item.family,
      target: "ibkr_item_#{ibkr_item.id}",
      partial: "ibkr_items/ibkr_item",
      locals: { ibkr_item: ibkr_item }
    )

    ibkr_item.family.broadcast_sync_complete
  end
end
