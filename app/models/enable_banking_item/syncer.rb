class EnableBankingItem::Syncer
  attr_reader :enable_banking_item

  def initialize(enable_banking_item)
    @enable_banking_item = enable_banking_item
  end

  def perform_sync(sync)
    # Loads item metadata, accounts, transactions, and other data to our DB
    enable_banking_item.import_latest_data

    # Processes the raw Enable Banking data and updates internal domain objects
    enable_banking_item.process_accounts

    # All data is synced, so we can now run an account sync to calculate historical balances and more
    enable_banking_item.schedule_account_syncs(
      parent_sync: sync,
      window_start_date: sync.window_start_date,
      window_end_date: sync.window_end_date
    )
  end

  def perform_post_sync
    # no-op
  end
end
