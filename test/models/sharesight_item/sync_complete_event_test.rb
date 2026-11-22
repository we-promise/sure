require "test_helper"

class SharesightItem::SyncCompleteEventTest < ActiveSupport::TestCase
  test "broadcast refreshes linked accounts and the family stream" do
    family = families(:dylan_family)
    sharesight_item = family.sharesight_items.create!(
      name: "Sharesight",
      client_id: "client-id",
      client_secret: "client-secret"
    )
    account = mock("account")

    sharesight_item.stubs(:accounts).returns([ account ])
    account.expects(:broadcast_sync_complete).once
    family.expects(:broadcast_sync_complete).once

    SharesightItem::SyncCompleteEvent.new(sharesight_item).broadcast
  end
end
