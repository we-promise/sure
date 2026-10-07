class AddUniqueIndexForValuationPerAccountAndDate < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_entries_on_account_and_date_for_valuations"

  def up
    # index_exists? alone isn't enough: CREATE INDEX CONCURRENTLY leaves an
    # INVALID index behind if it's interrupted (e.g. a deploy killed
    # mid-build), and index_exists? still reports that catalog entry as
    # present - short-circuiting here would record this migration as
    # applied while the constraint is actually missing/broken.
    return if valid_index_exists?

    # Clean up any leftover invalid index from a previous failed attempt so
    # the rebuild below doesn't fail with "relation already exists".
    execute "DROP INDEX CONCURRENTLY IF EXISTS #{INDEX_NAME}"

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
    # An installation hit by that race already has duplicate (account_id,
    # date) valuations, and PostgreSQL can't build a unique index on top of
    # them. Aborting here would stop a self-hosted upgrade at boot, so keep
    # the most recently updated valuation per account and date (the value
    # the user saw last) and remove the others. The account's next sync
    # rebuilds its balances from what is left.
    remove_duplicate_valuations

    add_index :entries, [ :account_id, :date ],
              unique: true,
              where: "(entryable_type = 'Valuation')",
              name: INDEX_NAME,
              algorithm: :concurrently
  end

  def down
    remove_index :entries, name: INDEX_NAME, if_exists: true, algorithm: :concurrently
  end

  private
    def remove_duplicate_valuations
      duplicates = select_rows(<<~SQL.squish)
        SELECT id, entryable_id FROM (
          SELECT id, entryable_id,
                 ROW_NUMBER() OVER (
                   PARTITION BY account_id, date
                   ORDER BY updated_at DESC, created_at DESC, id DESC
                 ) AS position
          FROM entries
          WHERE entryable_type = 'Valuation'
        ) ranked
        WHERE position > 1
      SQL
      return if duplicates.empty?

      entry_ids = duplicates.map(&:first)
      valuation_ids = duplicates.map(&:last)

      transaction do
        execute "DELETE FROM entries WHERE id IN (#{entry_ids.map { |id| quote(id) }.join(", ")})"
        execute "DELETE FROM valuations WHERE id IN (#{valuation_ids.map { |id| quote(id) }.join(", ")})"
      end

      say "Removed #{entry_ids.size} duplicate valuation entries: #{entry_ids.join(", ")}"
    end

    def valid_index_exists?
      select_value(<<~SQL.squish) == true
        SELECT indisvalid FROM pg_index
        JOIN pg_class ON pg_class.oid = pg_index.indexrelid
        WHERE pg_class.relname = '#{INDEX_NAME}'
      SQL
    end
end
