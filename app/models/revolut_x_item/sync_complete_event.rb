# frozen_string_literal: true

class RevolutXItem::SyncCompleteEvent
  def initialize(revolut_x_item)
    raise ArgumentError, "revolut_x_item is required" unless revolut_x_item.respond_to?(:family) && revolut_x_item.respond_to?(:id)

    @revolut_x_item = revolut_x_item
  end

  def broadcast
    # Not the rendered card: it lists every account on the connection and a
    # broadcast has no viewer to filter for. The toast re-fetches the page
    # per viewer.
    @revolut_x_item.family.broadcast_sync_complete
  rescue StandardError => e
    Rails.logger.warn("RevolutXItem::SyncCompleteEvent failed for #{@revolut_x_item.id}: #{e.class}")
  end
end
