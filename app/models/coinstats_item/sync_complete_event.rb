# Broadcasts Turbo Stream updates when a CoinStats sync completes.
# Updates account views and notifies the family of sync completion.
class CoinstatsItem::SyncCompleteEvent
  attr_reader :coinstats_item

  # @param coinstats_item [CoinstatsItem] The item that completed syncing
  def initialize(coinstats_item)
    @coinstats_item = coinstats_item
  end

  # Broadcasts sync completion to update UI components.
  def broadcast
    # Update UI with latest account data
    coinstats_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    # Update the CoinStats item view
    coinstats_item.broadcast_replace_to(
      coinstats_item.family,
      target: "coinstats_item_#{coinstats_item.id}",
      partial: "coinstats_items/coinstats_item",
      locals: { coinstats_item: coinstats_item }
    )

    # Let family handle sync notifications
    coinstats_item.family.broadcast_sync_complete
  end
end
