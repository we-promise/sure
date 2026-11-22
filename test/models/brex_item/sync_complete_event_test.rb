require "test_helper"

class BrexItem::SyncCompleteEventTest < ActiveSupport::TestCase
  fixtures :families, :brex_items

  test "broadcast refreshes linked accounts and the family stream" do
    brex_item = brex_items(:one)
    family = brex_item.family
    account = mock("account")

    brex_item.stubs(:accounts).returns([ account ])
    account.expects(:broadcast_sync_complete).once
    family.expects(:broadcast_sync_complete).once

    BrexItem::SyncCompleteEvent.new(brex_item).broadcast
  end
end
