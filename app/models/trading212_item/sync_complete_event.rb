class Trading212Item::SyncCompleteEvent
  attr_reader :trading212_item

  def initialize(trading212_item)
    @trading212_item = trading212_item
  end

  # This runs in SyncJob (no Current.user) and broadcasts on the family-wide
  # stream, so the whole card — whose account list is scoped per viewer — is
  # never re-rendered here. Instead, only the viewer-independent parts of the
  # card (sync status line and sync summary) are replaced, so live status
  # updates keep working. Account rows are refreshed individually: each
  # target only exists for viewers who can already see that account.
  def broadcast
    trading212_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    trading212_item.broadcast_replace_to(
      trading212_item.family,
      target: ActionView::RecordIdentifier.dom_id(trading212_item, :sync_status),
      partial: "trading212_items/sync_status",
      locals: { trading212_item: trading212_item }
    )

    trading212_item.broadcast_replace_to(
      trading212_item.family,
      target: ActionView::RecordIdentifier.dom_id(trading212_item, :sync_summary),
      partial: "trading212_items/sync_summary",
      locals: { trading212_item: trading212_item }
    )

    trading212_item.family.broadcast_sync_complete
  end
end
