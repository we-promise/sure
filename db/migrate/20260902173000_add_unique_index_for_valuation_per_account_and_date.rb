class AddUniqueIndexForValuationPerAccountAndDate < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def up
    # Business rule already enforced in application code
    # (Account::ReconciliationManager#prepare_reconciliation reuses the
    # existing valuation for a date instead of building a new one), but not
    # backed by the database: two concurrent reconciliation requests for the
    # same account+date can both pass that check before either saves,
    # producing two valuation entries for the same date. This index makes
    # the existing business rule authoritative at the DB level, the same way
    # index_entries_on_account_source_and_external_id already does for
    # provider-sourced entries.
    add_index :entries, [ :account_id, :date ],
              unique: true,
              where: "(entryable_type = 'Valuation')",
              name: "index_entries_on_account_and_date_for_valuations",
              algorithm: :concurrently
  end

  def down
    remove_index :entries, name: "index_entries_on_account_and_date_for_valuations", if_exists: true
  end
end
