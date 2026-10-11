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

    # The Settings > Providers panel is not streamed here: it is admin-only and
    # holds the connection's credentials, and every family member subscribes to
    # this stream. The sync toast below makes each browser re-fetch its own page.

    # Let family handle sync notifications
    family.broadcast_sync_complete
  end
end
