class AddCostBasisCarriedToHoldings < ActiveRecord::Migration[8.1]
  def change
    add_column :holdings, :cost_basis_carried, :boolean, default: false, null: false

    up_only { execute self.class.backfill_sql }
  end

  # Locks the provider import already copied forward onto each new day's row
  # are copies, not locks of the user's own: a provider row whose previous row
  # from the same provider is locked at the same figure, as the import chose
  # it. Rows the import did not write are left as the user's. A remapped row
  # is matched by its security only, so a copy across a remap stays unmarked.
  # A user who re-locked a provider row at the figure already there cannot be
  # told from a copy; marked carried, the earlier lock still carries it.
  def self.backfill_sql
    <<~SQL
      UPDATE holdings
      SET cost_basis_carried = TRUE
      WHERE holdings.cost_basis_locked
        AND EXISTS (
          SELECT 1 FROM holdings previous
          WHERE previous.account_id = holdings.account_id
            AND previous.account_provider_id = holdings.account_provider_id
            AND previous.security_id = holdings.security_id
            AND previous.currency = holdings.currency
            AND previous.cost_basis_locked
            AND previous.cost_basis IS NOT DISTINCT FROM holdings.cost_basis
            AND previous.date = (
              SELECT MAX(earlier.date) FROM holdings earlier
              WHERE earlier.account_id = holdings.account_id
                AND earlier.account_provider_id = holdings.account_provider_id
                AND earlier.security_id = holdings.security_id
                AND earlier.currency = holdings.currency
                AND earlier.date < holdings.date
            )
        )
    SQL
  end
end
