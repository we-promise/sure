class LunchflowItem::SyncCompleteEvent
  attr_reader :lunchflow_item

  def initialize(lunchflow_item)
    @lunchflow_item = lunchflow_item
  end

  def broadcast
    # Update UI with latest account data
    lunchflow_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    # Update the Lunchflow item view
    lunchflow_item.broadcast_replace_to(
      lunchflow_item.family,
      target: "lunchflow_item_#{lunchflow_item.id}",
      partial: "lunchflow_items/lunchflow_item",
      locals: { lunchflow_item: lunchflow_item }
    )

    # Let family handle sync notifications
    lunchflow_item.family.broadcast_sync_complete
  end
end
