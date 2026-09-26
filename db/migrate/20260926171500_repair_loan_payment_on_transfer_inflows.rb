# Until the import adapter stopped re-applying its guessed kind to entries that
# transfer matching had already paired (#3063), every sync re-stamped the inflow
# leg of a matched loan repayment as loan_payment. The income statement counts
# loan_payment as an expense, so those payments were counted twice.
#
# Every path that creates a transfer (auto_match_transfers!, TransferMatchesController,
# Transfer::Creator, Family::DataImporter) gives the inflow leg funds_movement, so a
# loan_payment on an inflow leg can only be that stale stamp.
class RepairLoanPaymentOnTransferInflows < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE transactions
      SET kind = 'funds_movement'
      WHERE kind = 'loan_payment'
        AND id IN (SELECT inflow_transaction_id FROM transfers)
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
