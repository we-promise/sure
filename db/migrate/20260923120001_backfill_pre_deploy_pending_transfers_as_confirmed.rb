class BackfillPreDeployPendingTransfersAsConfirmed < ActiveRecord::Migration[8.1]
  # Before this release, Transfer#status defaulted to "pending" by accident:
  # the old auto-match path (Family::AutoTransferMatchable#auto_match_transfers!)
  # created transfers via find_or_create_by! without ever setting status, but it
  # DID apply kind/category immediately at match time. So every pre-existing
  # auto-matched transfer sits at status="pending" with kind already set --
  # unlike the new pending suggestions this release introduces, whose legs stay
  # kind == "standard" until a human confirms them.
  #
  # Left alone, those old rows would appear in the new /auto_matches review
  # queue looking identical to real suggestions, except confirming one is a
  # silent no-op (Transfer#confirm! now only re-derives kind when both legs are
  # still "standard", per the same-day fix to that guard). Mark them confirmed
  # directly since their kind/category were already applied by the old code
  # and never should have been reviewable in the first place.
  def up
    execute <<~SQL
      UPDATE transfers
      SET status = 'confirmed'
      WHERE status = 'pending'
        AND EXISTS (
          SELECT 1 FROM transactions inflow_txn
          WHERE inflow_txn.id = transfers.inflow_transaction_id
            AND inflow_txn.kind <> 'standard'
        )
        AND EXISTS (
          SELECT 1 FROM transactions outflow_txn
          WHERE outflow_txn.id = transfers.outflow_transaction_id
            AND outflow_txn.kind <> 'standard'
        )
    SQL
  end

  def down
    # Irreversible: we can't distinguish "was pending pre-deploy" from
    # "confirmed normally after this migration ran" once both are status =
    # "confirmed". Re-running the up migration's WHERE clause in reverse
    # would also wrongly flip legitimately confirmed transfers back to
    # pending.
    raise ActiveRecord::IrreversibleMigration
  end
end
