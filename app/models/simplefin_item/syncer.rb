class SimplefinItem::Syncer
  attr_reader :simplefin_item

  def initialize(simplefin_item)
    @simplefin_item = simplefin_item
  end

  def perform_sync(sync)
    # Loads item metadata, accounts, transactions from SimpleFin API
    simplefin_item.import_latest_simplefin_data

    # Check if we have new SimpleFin accounts that need setup
    unlinked_accounts = simplefin_item.simplefin_accounts.includes(:account).where(accounts: { id: nil })
    if unlinked_accounts.any?
      # Mark as pending account setup so user can choose account types
      simplefin_item.update!(pending_account_setup: true)
      return
    end

    # Processes the raw SimpleFin data and updates internal domain objects
    simplefin_item.process_accounts

    # All data is synced, so we can now run an account sync to calculate historical balances and more
    simplefin_item.schedule_account_syncs(
      parent_sync: sync,
      window_start_date: sync.window_start_date,
      window_end_date: sync.window_end_date
    )
  end

  def perform_post_sync
    # no-op
  end
end
