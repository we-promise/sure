# frozen_string_literal: true

class OnchainWalletItem::SyncCompleteEvent
  def initialize(onchain_wallet_item)
    @onchain_wallet_item = onchain_wallet_item
  end

  def broadcast
    # Not the rendered wallet row: it names every address on the connection
    # and a broadcast has no viewer to filter for (#3630). The toast re-fetches
    # the page per viewer.
    @onchain_wallet_item.family.broadcast_sync_complete
  rescue StandardError => e
    Rails.logger.warn("OnchainWalletItem::SyncCompleteEvent failed for #{@onchain_wallet_item.id}: #{e.class}")
  end
end
