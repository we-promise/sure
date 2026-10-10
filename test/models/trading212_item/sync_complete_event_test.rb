require "test_helper"

class Trading212Item::SyncCompleteEventTest < ActiveSupport::TestCase
  fixtures :families, :trading212_items

  test "broadcast refreshes accounts, viewer-independent card parts, and family stream" do
    trading212_item = trading212_items(:configured_item)
    family = trading212_item.family
    account = mock("account")

    trading212_item.stubs(:accounts).returns([ account ])
    account.expects(:broadcast_sync_complete).once
    trading212_item.expects(:broadcast_replace_to).with(
      family,
      target: "sync_status_trading212_item_#{trading212_item.id}",
      partial: "trading212_items/sync_status",
      locals: { trading212_item: trading212_item }
    ).once
    trading212_item.expects(:broadcast_replace_to).with(
      family,
      target: "sync_summary_trading212_item_#{trading212_item.id}",
      partial: "trading212_items/sync_summary",
      locals: { trading212_item: trading212_item }
    ).once
    family.expects(:broadcast_sync_complete).once

    Trading212Item::SyncCompleteEvent.new(trading212_item).broadcast
  end

  test "never re-renders the whole viewer-scoped card" do
    trading212_item = trading212_items(:configured_item)
    trading212_item.stubs(:accounts).returns([])
    trading212_item.family.stubs(:broadcast_sync_complete)
    trading212_item.stubs(:broadcast_replace_to)
    trading212_item.expects(:broadcast_replace_to).with(anything, has_entry(:partial, "trading212_items/trading212_item")).never

    Trading212Item::SyncCompleteEvent.new(trading212_item).broadcast
  end
end
