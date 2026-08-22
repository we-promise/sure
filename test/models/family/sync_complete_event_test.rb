require "test_helper"

class Family::SyncCompleteEventTest < ActiveSupport::TestCase
  fixtures :families

  test "broadcast replaces both the sync toast and the accounts page's own sync controls" do
    family = families(:dylan_family)

    family.expects(:broadcast_replace_to).with(
      family,
      target: "sync-toast",
      partial: "shared/notifications/sync_toast"
    ).once

    family.expects(:broadcast_replace_to).with(
      family,
      target: "accounts-sync-controls",
      partial: "accounts/sync_controls",
      locals: { family: family }
    ).once

    Family::SyncCompleteEvent.new(family).broadcast
  end
end
