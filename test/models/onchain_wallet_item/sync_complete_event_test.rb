# frozen_string_literal: true

require "test_helper"
require "turbo/broadcastable/test_helper"

class OnchainWalletItem::SyncCompleteEventTest < ActiveSupport::TestCase
  include OnchainTestHelper
  include Turbo::Broadcastable::TestHelper

  setup do
    register_fake_chain!
    @item = create_onchain_wallet_item(family: families(:dylan_family))
    @onchain_account = create_onchain_wallet_account(item: @item, asset: fake_native_asset(quantity: 0))
    link_onchain_wallet_account!(@onchain_account)
  end

  teardown do
    unregister_fake_chain!
  end

  # #3630. The wallet row names every address on the connection, and every
  # family member subscribes to the family stream, including members the
  # wallet's accounts are not shared with.
  test "a sync completion sends the family toast instead of the rendered wallet row" do
    streams = capture_turbo_stream_broadcasts(@item.family) do
      OnchainWalletItem::SyncCompleteEvent.new(@item).broadcast
    end

    targets = streams.map { |stream| stream["target"] }
    assert_not_includes targets, ActionView::RecordIdentifier.dom_id(@item)
    assert_includes targets, "sync-toast"
    streams.each { |stream| assert_not_includes stream.to_html, @onchain_account.truncated_address }
  end
end
