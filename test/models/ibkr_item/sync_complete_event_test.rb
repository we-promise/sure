require "test_helper"

class IbkrItem::SyncCompleteEventTest < ActiveSupport::TestCase
  fixtures :families, :ibkr_items

  test "broadcast refreshes linked accounts, provider item, and family stream" do
    ibkr_item = ibkr_items(:configured_item)
    family = ibkr_item.family
    account = mock("account")

    ibkr_item.stubs(:accounts).returns([ account ])
    account.expects(:broadcast_sync_complete).once
    ibkr_item.expects(:broadcast_replace_to).with(
      family,
      target: "ibkr_item_#{ibkr_item.id}",
      partial: "ibkr_items/ibkr_item",
      locals: { ibkr_item: ibkr_item }
    ).once
    family.expects(:broadcast_sync_complete).once

    IbkrItem::SyncCompleteEvent.new(ibkr_item).broadcast
  end
end
