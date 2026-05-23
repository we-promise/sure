# frozen_string_literal: true

class BitstampItem::SyncCompleteEvent
  def initialize(bitstamp_item)
    raise ArgumentError, "bitstamp_item is required" unless bitstamp_item.respond_to?(:family) && bitstamp_item.respond_to?(:id)

    @bitstamp_item = bitstamp_item
  end

  def broadcast
    Turbo::StreamsChannel.broadcast_replace_to(
      @bitstamp_item.family,
      target: ActionView::RecordIdentifier.dom_id(@bitstamp_item),
      partial: "bitstamp_items/bitstamp_item",
      locals: { bitstamp_item: @bitstamp_item }
    )
  rescue StandardError => e
    Rails.logger.warn("BitstampItem::SyncCompleteEvent failed for #{@bitstamp_item.id}: #{e.class}")
  end
end
