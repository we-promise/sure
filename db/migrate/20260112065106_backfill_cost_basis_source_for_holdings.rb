class BackfillCostBasisSourceForHoldings < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def up
    # Backfill cost_basis_source for existing holdings that have cost_basis but no source
    # This is safe - it only adds metadata, doesn't change actual cost_basis values
    # Locks existing data by default to protect it - users can unlock if they want syncs to update

    say_with_time "Backfilling cost_basis_source for holdings" do
      updated = 0

      # Process in batches to avoid locking issues
      Holding.where.not(cost_basis: nil)
             .where(cost_basis_source: nil)
             .where("cost_basis > 0")
             .find_each do |holding|
        # Heuristic: If holding's account has buy trades for this security, likely calculated
        # Otherwise, likely from provider (SimpleFIN/Plaid/Lunchflow)
        has_trades = holding.account.trades
                           .where(security_id: holding.security_id)
                           .where("qty > 0")
                           .exists?

        source = has_trades ? "calculated" : "provider"

        # Lock existing data to protect it - users can unlock via UI if they want syncs to update
        holding.update_columns(cost_basis_source: source, cost_basis_locked: true)
        updated += 1
      end

      updated
    end
  end

  def down
    # Reversible: clear the source and unlock for holdings that were backfilled
    # We can't know for sure which ones were backfilled vs manually set,
    # but clearing all non-manual sources is safe since they'd be re-detected
    Holding.where(cost_basis_source: %w[calculated provider])
           .update_all(cost_basis_source: nil, cost_basis_locked: false)
  end
end
