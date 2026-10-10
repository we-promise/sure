# Broadcasts Turbo Stream updates when a Coinbase sync completes.
# Updates account views and notifies the family of sync completion.
class CoinbaseItem::SyncCompleteEvent
  attr_reader :coinbase_item

  # @param coinbase_item [CoinbaseItem] The item that completed syncing
  def initialize(coinbase_item)
    @coinbase_item = coinbase_item
  end

  # Broadcasts sync completion to update UI components.
  def broadcast
    # Update UI with latest account data
    coinbase_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    # Let family handle sync notifications
    coinbase_item.family.broadcast_sync_complete
  end
end
