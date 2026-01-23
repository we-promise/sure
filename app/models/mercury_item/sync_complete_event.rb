class MercuryItem::SyncCompleteEvent
  attr_reader :mercury_item

  def initialize(mercury_item)
    @mercury_item = mercury_item
  end

  def broadcast
    # Update UI with latest account data
    mercury_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    # Update the Mercury item view
    mercury_item.broadcast_replace_to(
      mercury_item.family,
      target: "mercury_item_#{mercury_item.id}",
      partial: "mercury_items/mercury_item",
      locals: { mercury_item: mercury_item }
    )

    # Let family handle sync notifications
    mercury_item.family.broadcast_sync_complete
  end
end
