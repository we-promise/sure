class Trading212Item::SyncCompleteEvent
  attr_reader :trading212_item

  def initialize(trading212_item)
    @trading212_item = trading212_item
  end

  # The Trading212 card lists only the accounts the viewing user can access,
  # so it is not re-rendered here: this runs in SyncJob with no Current.user,
  # and the family-wide stream would send the same HTML to every member.
  # Account rows are refreshed individually (each target only exists for
  # viewers who can already see that account), and the family sync toast makes
  # each browser re-fetch the page on its own authenticated request.
  def broadcast
    trading212_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    trading212_item.family.broadcast_sync_complete
  end
end
