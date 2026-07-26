class RedbarkItem::SyncCompleteEvent
  attr_reader :redbark_item

  def initialize(redbark_item)
    @redbark_item = redbark_item
  end

  def broadcast
    # Update UI with latest account data
    redbark_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    # Update the Redbark item view
    redbark_item.broadcast_replace_to(
      redbark_item.family,
      target: "redbark_item_#{redbark_item.id}",
      partial: "redbark_items/redbark_item",
      locals: { redbark_item: redbark_item }
    )

    # Let family handle sync notifications
    redbark_item.family.broadcast_sync_complete
  end
end
