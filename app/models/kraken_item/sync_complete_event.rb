# frozen_string_literal: true

class KrakenItem::SyncCompleteEvent
  def initialize(kraken_item)
    raise ArgumentError, "kraken_item is required" unless kraken_item.respond_to?(:family) && kraken_item.respond_to?(:id)

    @kraken_item = kraken_item
  end

  def broadcast
    # Not the rendered card: it lists every account on the connection and a
    # broadcast has no viewer to filter for (#3630). The toast re-fetches the
    # page per viewer.
    @kraken_item.family.broadcast_sync_complete
  rescue StandardError => e
    Rails.logger.warn("KrakenItem::SyncCompleteEvent failed for #{@kraken_item.id}: #{e.class}")
  end
end
