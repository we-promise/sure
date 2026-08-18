# frozen_string_literal: true

require "test_helper"

class OnchainWalletItem::SyncCompleteEventTest < ActiveSupport::TestCase
  include ActionView::RecordIdentifier

  test "broadcast refreshes settings panel and accounts provider card" do
    item = OnchainWalletItem.create!(family: families(:dylan_family), name: "On-chain Wallets")

    Turbo::StreamsChannel.expects(:broadcast_replace_to).with(
      item.family,
      target: "onchain-wallet-providers-panel",
      partial: "settings/providers/onchain_wallet_panel",
      locals: { onchain_wallet_items: item.family.onchain_wallet_items.active.ordered }
    ).once
    Turbo::StreamsChannel.expects(:broadcast_replace_to).with(
      item.family,
      target: dom_id(item),
      partial: "onchain_wallet_items/onchain_wallet_item",
      locals: { onchain_wallet_item: item }
    ).once

    OnchainWalletItem::SyncCompleteEvent.new(item).broadcast
  end
end
