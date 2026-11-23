class BackfillBatchMaterializedHoldings < ActiveRecord::Migration[8.1]
  def up
    # A bulk holding write shares both timestamps across multiple dates, even
    # when the balances for those dates were already present.
    # Imports saved each row separately and can replace a holding after sync.
    # A balance rewrite cannot confirm who last wrote a singleton holding.
    execute <<~SQL
      WITH holding_batches AS (
        SELECT account_id, security_id, currency, created_at, updated_at
        FROM holdings
        WHERE created_at <> updated_at
        GROUP BY account_id, security_id, currency, created_at, updated_at
        HAVING COUNT(*) > 1
      )
      UPDATE holdings
      SET materialized = true
      WHERE materialized = false
        AND account_provider_id IS NULL
        AND provider_security_id IS NULL
        AND external_id IS NULL
        AND cost_basis_locked = false
        AND security_locked = false
        AND (account_id, security_id, currency, created_at, updated_at) IN (
          SELECT account_id, security_id, currency, created_at, updated_at FROM holding_batches
        )
        AND EXISTS (
          SELECT 1
          FROM entries
          JOIN trades ON entries.entryable_id = trades.id
          WHERE entries.entryable_type = 'Trade'
            AND entries.account_id = holdings.account_id
            AND entries.date <= holdings.date
            AND trades.security_id = holdings.security_id
            AND trades.qty <> 0
        )
    SQL
  end

  def down
    # Keep verified provenance until the materialized column itself is removed.
  end
end
