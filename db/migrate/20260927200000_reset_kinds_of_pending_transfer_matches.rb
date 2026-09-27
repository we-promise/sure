# Auto-matched transfers used to set the transfer kinds (and the Investment
# Contributions category) as soon as they were suggested. They now stay
# untouched until the user confirms the match, and rejecting a pending match
# no longer resets kinds, so pending matches left over from before would keep
# their transfer kinds forever. Put their transactions back to standard;
# Transfer#confirm! sets the kinds again when the match is confirmed.
class ResetKindsOfPendingTransferMatches < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE transactions
      SET kind = 'standard'
      WHERE kind IN ('funds_movement', 'cc_payment', 'loan_payment', 'investment_contribution')
        AND id IN (
          SELECT inflow_transaction_id FROM transfers WHERE status = 'pending'
          UNION
          SELECT outflow_transaction_id FROM transfers WHERE status = 'pending'
        )
    SQL
  end

  # The kinds are set again by Transfer#confirm!.
  def down
  end
end
