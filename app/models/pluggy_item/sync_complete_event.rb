# frozen_string_literal: true

class PluggyItem::SyncCompleteEvent
  attr_reader :pluggy_item

  def initialize(pluggy_item)
    @pluggy_item = pluggy_item
  end

  def broadcast
    pluggy_item.accounts.each(&:broadcast_sync_complete)

    pluggy_item.broadcast_replace_to(
      pluggy_item.family,
      target: dom_id(pluggy_item),
      partial: "pluggy_items/pluggy_item",
      locals: { pluggy_item: pluggy_item }
    )

    pluggy_item.family.broadcast_sync_complete
  end

  private

    def dom_id(record)
      "#{record.class.name.underscore}_#{record.id}"
    end
end