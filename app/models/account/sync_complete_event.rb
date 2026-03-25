class Account::SyncCompleteEvent
  attr_reader :account

  Error = Class.new(StandardError)

  def initialize(account)
    @account = account
  end

  def broadcast
    # Replace account row in accounts list
    account.broadcast_replace_to(
      account.family,
      target: "account_#{account.id}",
      partial: "accounts/account",
      locals: { account: account }
    )

    # If this is a manual, unlinked account (i.e. not part of a Plaid Item),
    # trigger the family sync complete broadcast so net worth graph is updated
    unless account.linked?
      account.family.broadcast_sync_complete
    end

    # Refresh entire account page (only applies if currently viewing this account)
    account.broadcast_refresh
  end
end
