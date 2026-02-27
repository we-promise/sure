class AddPerformanceIndexes < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    # entries.excluded: frequently filtered in stale pending cleanup and reconciliation
    add_index :entries, :excluded,
              name: "index_entries_on_excluded",
              algorithm: :concurrently

    # entries(account_id, excluded, date): covers the common pattern of filtering an
    # account's non-excluded entries ordered by date (reconcile_pending_duplicates, show page)
    add_index :entries, [ :account_id, :excluded, :date ],
              name: "index_entries_on_account_id_excluded_date",
              order: { date: :desc },
              algorithm: :concurrently

    # holdings(account_id, date): used by Holding#day_change which queries
    # "most recent holding before a given date" for each holding rendered
    add_index :holdings, [ :account_id, :date ],
              name: "index_holdings_on_account_id_and_date",
              order: { date: :desc },
              algorithm: :concurrently

    # accounts.classification: virtual stored column queried by Account.assets /
    # Account.liabilities scopes used throughout balance sheet and income statement
    add_index :accounts, :classification,
              name: "index_accounts_on_classification",
              algorithm: :concurrently
  end
end
