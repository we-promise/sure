class SophtronItem::SyncCompleteEvent
  attr_reader :sophtron_item

  def initialize(sophtron_item)
    @sophtron_item = sophtron_item
  end

  def broadcast
    # Update UI with latest account data
    sophtron_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    # Update the Sophtron item view
    sophtron_item.broadcast_replace_to(
      sophtron_item.family,
      target: "sophtron_item_#{sophtron_item.id}",
      partial: "sophtron_items/sophtron_item",
      locals: { sophtron_item: sophtron_item }
    )

    # Let family handle sync notifications
    sophtron_item.family.broadcast_sync_complete
  end
end
