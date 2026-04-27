class GocardlessItem::SyncCompleteEvent
  attr_reader :gocardless_item

  def initialize(gocardless_item)
    @gocardless_item = gocardless_item
  end

  def broadcast
    gocardless_item.reload

    # Update UI with latest account data
    gocardless_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    family = gocardless_item.family
    return unless family

    # Update the GoCardless item view on the Accounts page
    gocardless_item.broadcast_replace_to(
      family,
      target: "gocardless_item_#{gocardless_item.id}",
      partial: "gocardless_items/gocardless_item",
      locals: { gocardless_item: gocardless_item }
    )

    # Update the Settings > Providers panel
    gocardless_items = family.gocardless_items.active.ordered
    gocardless_item.broadcast_replace_to(
      family,
      target: "gocardless-providers-panel",
      partial: "settings/providers/gocardless_panel",
      locals: { gocardless_items: gocardless_items, family: family }
    )

    # Let family handle sync notifications
    family.broadcast_sync_complete
  end
end