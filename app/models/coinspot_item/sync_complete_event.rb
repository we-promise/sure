# frozen_string_literal: true

class CoinspotItem::SyncCompleteEvent
  # Wraps the CoinspotItem to broadcast a sync-complete update for.
  def initialize(coinspot_item)
    unless coinspot_item.respond_to?(:family) && coinspot_item.respond_to?(:id)
      raise ArgumentError, "coinspot_item is required"
    end

    @coinspot_item = coinspot_item
  end

  # Turbo-broadcasts a re-render of this connection's card so its sync
  # status updates live in the browser without a page reload. Logs and
  # swallows failures -- a broadcast issue shouldn't fail the sync itself.
  def broadcast
    Turbo::StreamsChannel.broadcast_replace_to(
      @coinspot_item.family,
      target: ActionView::RecordIdentifier.dom_id(@coinspot_item),
      partial: "coinspot_items/coinspot_item",
      locals: { coinspot_item: @coinspot_item }
    )
  rescue StandardError => e
    Rails.logger.warn("CoinspotItem::SyncCompleteEvent failed for #{@coinspot_item.id}: #{e.class}")
  end
end
