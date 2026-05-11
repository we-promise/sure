# frozen_string_literal: true

class KrakenItem::SyncCompleteEvent
  def initialize(kraken_item)
    raise ArgumentError, "kraken_item is required" unless kraken_item.respond_to?(:family) && kraken_item.respond_to?(:id)

    @kraken_item = kraken_item
  end

  def broadcast
    Turbo::StreamsChannel.broadcast_replace_to(
      @kraken_item.family,
      target: ActionView::RecordIdentifier.dom_id(@kraken_item),
      partial: "kraken_items/kraken_item",
      locals: { kraken_item: @kraken_item }
    )
  rescue StandardError => e
    Rails.logger.warn("KrakenItem::SyncCompleteEvent failed for #{@kraken_item.id}: #{e.class}")
  end
end
