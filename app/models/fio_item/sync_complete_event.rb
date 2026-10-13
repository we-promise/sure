# frozen_string_literal: true

class FioItem::SyncCompleteEvent
  attr_reader :fio_item

  def initialize(fio_item)
    @fio_item = fio_item
  end

  # Broadcast sync-complete Turbo updates for the item, its accounts, and family.
  def broadcast
    fio_item.accounts.each(&:broadcast_sync_complete)

    fio_item.broadcast_replace_to(
      fio_item.family,
      target: "fio_item_#{fio_item.id}",
      partial: "fio_items/fio_item",
      locals: { fio_item: fio_item }
    )

    fio_item.family.broadcast_sync_complete
  end
end
