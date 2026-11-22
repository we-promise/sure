require "test_helper"

class QuestradeItem::SyncCompleteEventTest < ActiveSupport::TestCase
  fixtures :families, :questrade_items

  test "broadcast refreshes linked accounts and the family stream" do
    questrade_item = questrade_items(:one)
    family = questrade_item.family
    account = mock("account")

    questrade_item.stubs(:accounts).returns([ account ])
    account.expects(:broadcast_sync_complete).once
    family.expects(:broadcast_sync_complete).once

    QuestradeItem::SyncCompleteEvent.new(questrade_item).broadcast
  end
end
