require "test_helper"

class Trading212Item::SyncCompleteEventTest < ActiveSupport::TestCase
  fixtures :families, :trading212_items

  test "broadcast refreshes linked accounts and family stream without re-rendering the viewer-scoped card" do
    trading212_item = trading212_items(:configured_item)
    family = trading212_item.family
    account = mock("account")

    trading212_item.stubs(:accounts).returns([ account ])
    account.expects(:broadcast_sync_complete).once
    trading212_item.expects(:broadcast_replace_to).never
    family.expects(:broadcast_sync_complete).once

    Trading212Item::SyncCompleteEvent.new(trading212_item).broadcast
  end
end
