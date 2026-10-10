# frozen_string_literal: true

class CoinspotItem::SyncCompleteEvent
  # Wraps the CoinspotItem to broadcast a sync-complete update for.
  def initialize(coinspot_item)
    unless coinspot_item.respond_to?(:family) && coinspot_item.respond_to?(:id)
      raise ArgumentError, "coinspot_item is required"
    end

    @coinspot_item = coinspot_item
  end

  # Tells the family's browsers the sync finished, so each re-fetches the page
  # with its own permissions. Logs and swallows failures -- a broadcast issue
  # shouldn't fail the sync itself.
  def broadcast
    # Not the rendered card: it lists every account on the connection and a
    # broadcast has no viewer to filter for (#3630). The toast re-fetches the
    # page per viewer.
    @coinspot_item.family.broadcast_sync_complete
  rescue StandardError => e
    Rails.logger.warn("CoinspotItem::SyncCompleteEvent failed for #{@coinspot_item.id}: #{e.class}")
  end
end
