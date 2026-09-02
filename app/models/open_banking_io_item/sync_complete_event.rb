class OpenBankingIoItem::SyncCompleteEvent
  attr_reader :open_banking_io_item

  def initialize(open_banking_io_item)
    @open_banking_io_item = open_banking_io_item
  end

  def broadcast
    open_banking_io_item.accounts.each(&:broadcast_sync_complete)

    open_banking_io_item.broadcast_replace_to(
      open_banking_io_item.family,
      target: "open_banking_io_item_#{open_banking_io_item.id}",
      partial: "open_banking_io_items/open_banking_io_item",
      locals: { open_banking_io_item: open_banking_io_item }
    )

    open_banking_io_item.family.broadcast_sync_complete
  end
end
