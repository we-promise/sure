class AddCostBasisCarriedToHoldings < ActiveRecord::Migration[8.1]
  def change
    add_column :holdings, :cost_basis_carried, :boolean, default: false, null: false

    up_only { execute self.class.backfill_sql }
  end

  # Locks the provider import already copied forward onto each new day's row
  # are copies, not locks of the user's own: a locked row whose position's
  # previous row is locked at the same figure.
  def self.backfill_sql
    <<~SQL
      UPDATE holdings
      SET cost_basis_carried = TRUE
      WHERE holdings.cost_basis_locked
        AND EXISTS (
          SELECT 1 FROM holdings previous
          WHERE previous.account_id = holdings.account_id
            AND previous.security_id = holdings.security_id
            AND previous.currency = holdings.currency
            AND previous.cost_basis_locked
            AND previous.cost_basis IS NOT DISTINCT FROM holdings.cost_basis
            AND previous.date = (
              SELECT MAX(earlier.date) FROM holdings earlier
              WHERE earlier.account_id = holdings.account_id
                AND earlier.security_id = holdings.security_id
                AND earlier.currency = holdings.currency
                AND earlier.date < holdings.date
            )
        )
    SQL
  end
end
