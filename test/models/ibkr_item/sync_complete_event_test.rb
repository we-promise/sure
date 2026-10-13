require "test_helper"

class IbkrItem::SyncCompleteEventTest < ActiveSupport::TestCase
  fixtures :families, :ibkr_items

  # The card itself is not re-rendered: it lists every account on the
  # connection and a broadcast has no viewer to filter for (#3630).
  test "broadcast refreshes linked accounts and the family stream, not the card" do
    ibkr_item = ibkr_items(:configured_item)
    family = ibkr_item.family
    account = mock("account")

    ibkr_item.stubs(:accounts).returns([ account ])
    account.expects(:broadcast_sync_complete).once
    ibkr_item.expects(:broadcast_replace_to).never
    family.expects(:broadcast_sync_complete).once

    IbkrItem::SyncCompleteEvent.new(ibkr_item).broadcast
  end
end
