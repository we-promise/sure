require "test_helper"
require "turbo/broadcastable/test_helper"

class KrakenItem::SyncCompleteEventTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  # #3630. Kraken's event never sent the family toast; it relied on replacing
  # the card. With the card replace gone it must send the toast instead, or a
  # finished sync would leave the page stale.
  test "a sync completion sends the family toast instead of the rendered card" do
    item = kraken_items(:one)

    streams = capture_turbo_stream_broadcasts(item.family) do
      KrakenItem::SyncCompleteEvent.new(item).broadcast
    end

    targets = streams.map { |stream| stream["target"] }
    assert_not_includes targets, ActionView::RecordIdentifier.dom_id(item)
    assert_includes targets, "sync-toast"
  end
end
