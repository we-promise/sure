# A transferred position has no cost basis this app can know: the units were
# acquired somewhere else, at a price nothing here recorded. The calculators
# were counting the transfer's own price as a purchase, so those positions have
# a stored figure that reports a coin bought at 30k and moved in at 60k as
# having made no gain at all.
#
# `Holding#avg_cost` reads that stored value before it reaches the transfer
# guard, so the figure stands until the account materializes again — which for
# a manual or disconnected account may be never.
#
# Only figures this app worked out are cleared. A `manual` or `provider` basis
# is somebody asserting what the position cost, which is exactly the thing the
# app cannot derive for a transfer, and stays.
class ClearTransferredPositionCostBases < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL
      UPDATE holdings
      SET cost_basis = NULL, cost_basis_source = NULL
      WHERE cost_basis IS NOT NULL
        AND cost_basis_locked = false
        AND (cost_basis_source IS NULL OR cost_basis_source = 'calculated')
        AND EXISTS (
          SELECT 1
          FROM trades
          JOIN entries ON entries.entryable_id = trades.id
                      AND entries.entryable_type = 'Trade'
          WHERE trades.security_id = holdings.security_id
            AND entries.account_id = holdings.account_id
            AND trades.investment_activity_label = 'Transfer'
            AND entries.date <= holdings.date
        )
    SQL
  end

  # The cleared figures were wrong, and the correct value is "unknown". Putting
  # them back would mean recomputing the same fabrication.
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
