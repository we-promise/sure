class Account::SyncCompleteEvent
  attr_reader :account

  Error = Class.new(StandardError)

  def initialize(account)
    @account = account
  end

  def broadcast
    # The accounts list is not updated by replacing the row here: the row
    # shows the account's name and balance, and every family member holds
    # the family stream, including members the account is not shared with.
    # The sync toast makes each browser re-fetch its own page instead. It is
    # sent for linked accounts too, since one can sync on its own with no
    # provider event after it.
    account.family.broadcast_sync_complete

    # Refresh entire account page (only applies if currently viewing this account)
    account.broadcast_refresh
  end
end
