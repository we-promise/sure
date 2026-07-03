class AddInvestmentTotalsLookupIndexToEntries < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    add_index :entries,
              [ :account_id, :date, :entryable_id ],
              name: "index_entries_on_investment_totals_lookup",
              where: "entryable_type = 'Trade' AND excluded = false",
              algorithm: :concurrently
  end
end
