# frozen_string_literal: true

class OnchainWalletItem::SyncCompleteEvent
  def initialize(onchain_wallet_item)
    @onchain_wallet_item = onchain_wallet_item
  end

  def broadcast
    Turbo::StreamsChannel.broadcast_replace_to(
      @onchain_wallet_item.family,
      target: ActionView::RecordIdentifier.dom_id(@onchain_wallet_item),
      partial: "onchain_wallet_items/onchain_wallet_item",
      locals: { onchain_wallet_item: @onchain_wallet_item }
    )
  rescue StandardError => e
    Rails.logger.warn("OnchainWalletItem::SyncCompleteEvent failed for #{@onchain_wallet_item.id}: #{e.class}")
  end
end
