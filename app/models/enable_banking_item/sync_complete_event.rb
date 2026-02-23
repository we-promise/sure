class EnableBankingItem::SyncCompleteEvent
  attr_reader :enable_banking_item

  def initialize(enable_banking_item)
    @enable_banking_item = enable_banking_item
  end

  def broadcast
    enable_banking_item.reload

    # Update UI with latest account data
    enable_banking_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    family = enable_banking_item.family
    return unless family

    # Update the Enable Banking item view on the Accounts page
    enable_banking_item.broadcast_replace_to(
      family,
      target: "enable_banking_item_#{enable_banking_item.id}",
      partial: "enable_banking_items/enable_banking_item",
      locals: { enable_banking_item: enable_banking_item }
    )

    # Update the Settings > Providers panel
    enable_banking_items = family.enable_banking_items.ordered.includes(:syncs)
    enable_banking_item.broadcast_replace_to(
      family,
      target: "enable_banking-providers-panel",
      partial: "settings/providers/enable_banking_panel",
      locals: { enable_banking_items: enable_banking_items }
    )

    # Let family handle sync notifications
    family.broadcast_sync_complete
  end
end
