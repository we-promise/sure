require "test_helper"
require "turbo/broadcastable/test_helper"

class PlaidItem::SyncCompleteEventTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  # #3630. The card partial renders every account on the connection, and a sync
  # broadcast has no viewer to filter for. Replacing the card on the family
  # stream would swap a member's filtered card for the full one, so the card
  # is left to the family's sync toast, which re-fetches the page per viewer.
  test "a sync completion does not broadcast the rendered card" do
    item = plaid_items(:one)

    streams = capture_turbo_stream_broadcasts(item.family) do
      PlaidItem::SyncCompleteEvent.new(item).broadcast
    end

    targets = streams.map { |stream| stream["target"] }
    assert_not_includes targets, ActionView::RecordIdentifier.dom_id(item)
    assert_includes targets, "sync-toast"
  end
end
