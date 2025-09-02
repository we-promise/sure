class EnableBankingItem::SyncCompleteEvent
  attr_reader :enable_banking_item

  def initialize(enable_banking_item)
    @enable_banking_item = enable_banking_item
  end

  def broadcast
    enable_banking_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    enable_banking_item.broadcast_replace_to(
      enable_banking_item.family,
      target: "enable_banking_item_#{enable_banking_item.id}",
      partial: "enable_banking_items/enable_banking_item",
      locals: { enable_banking_item: enable_banking_item }
    )

    enable_banking_item.family.broadcast_sync_complete
  end
end
