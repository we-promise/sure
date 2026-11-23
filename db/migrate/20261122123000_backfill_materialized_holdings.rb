class BackfillMaterializedHoldings < ActiveRecord::Migration[8.1]
  def up
    # The balance materializer inserted both rows in the same transaction, so
    # PostgreSQL gave them the same created_at. Imports saved them separately.
    # Balances were written after holdings. A newer holding update may be an
    # import into the same row, so leave those rows alone.
    execute <<~SQL
      UPDATE holdings
      SET materialized = true
      WHERE materialized = false
        AND account_provider_id IS NULL
        AND provider_security_id IS NULL
        AND external_id IS NULL
        AND cost_basis_locked = false
        AND security_locked = false
        AND EXISTS (
          SELECT 1
          FROM balances
          WHERE balances.account_id = holdings.account_id
            AND balances.date = holdings.date
            AND balances.currency = holdings.currency
            AND balances.created_at = holdings.created_at
            AND balances.updated_at <> balances.created_at
            AND balances.updated_at >= holdings.updated_at
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
