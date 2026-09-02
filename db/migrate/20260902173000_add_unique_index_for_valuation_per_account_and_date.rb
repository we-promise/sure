class AddUniqueIndexForValuationPerAccountAndDate < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def up
    return if index_exists?(:entries, [ :account_id, :date ], unique: true, name: "index_entries_on_account_and_date_for_valuations")

    # CREATE INDEX CONCURRENTLY can leave an INVALID index behind if it's
    # interrupted (e.g. a deploy killed mid-build) - clean that up first so a
    # retry of this migration doesn't fail with "relation already exists".
    execute "DROP INDEX CONCURRENTLY IF EXISTS index_entries_on_account_and_date_for_valuations"

    # Business rule already enforced in application code
    # (Account::ReconciliationManager#prepare_reconciliation reuses the
    # existing valuation for a date instead of building a new one), but not
    # backed by the database: two concurrent reconciliation requests for the
    # same account+date can both pass that check before either saves,
    # producing two valuation entries for the same date. This index makes
    # the existing business rule authoritative at the DB level, the same way
    # index_entries_on_account_source_and_external_id already does for
    # provider-sourced entries.
    #
    # On an installation that already has duplicate (account_id, date)
    # valuations - the exact state the bug this migration fixes can produce
    # - PostgreSQL can't build a unique index on top of them. Following this
    # repo's existing convention for the same situation (see
    # ScopeLunchflowAccountUniquenessToItem), fail loudly with a clear
    # message instead of silently deleting financial data on someone's
    # behalf.
    if execute("SELECT 1 FROM entries WHERE entryable_type = 'Valuation' GROUP BY account_id, date HAVING COUNT(*) > 1 LIMIT 1").any?
      raise ActiveRecord::Migration::IrreversibleMigration,
            "Duplicate (account_id, date) Valuation entries exist. Resolve duplicates before running this migration."
    end

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
