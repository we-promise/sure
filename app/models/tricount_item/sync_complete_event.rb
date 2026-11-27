# frozen_string_literal: true

class TricountItem::SyncCompleteEvent
  def initialize(tricount_item)
    raise ArgumentError, "tricount_item is required" unless tricount_item.respond_to?(:family) && tricount_item.respond_to?(:id)

    @tricount_item = tricount_item
  end

  # The family's sync toast, not the rendered card: the card lists every
  # account on the connection and a broadcast has no viewer to filter for, so
  # each browser re-fetches its own page.
  def broadcast
    @tricount_item.family.broadcast_sync_complete
  rescue StandardError => e
    Rails.logger.warn("TricountItem::SyncCompleteEvent failed for #{@tricount_item.id}: #{e.class}")
  end
end
