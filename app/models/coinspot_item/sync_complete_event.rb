# frozen_string_literal: true

class CoinspotItem::SyncCompleteEvent
  def initialize(coinspot_item)
    unless coinspot_item.respond_to?(:family) && coinspot_item.respond_to?(:id)
      raise ArgumentError, "coinspot_item is required"
    end

    @coinspot_item = coinspot_item
  end

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
