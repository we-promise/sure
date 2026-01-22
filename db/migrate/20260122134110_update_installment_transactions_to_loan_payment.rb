class UpdateInstallmentTransactionsToLoanPayment < ActiveRecord::Migration[7.2]
  def up
    execute <<-SQL
      UPDATE transactions
      SET kind = 'loan_payment'
      WHERE extra->>'installment_id' IS NOT NULL
        AND kind = 'funds_movement'
    SQL
  end

  def down
    execute <<-SQL
      UPDATE transactions
      SET kind = 'funds_movement'
      WHERE extra->>'installment_id' IS NOT NULL
        AND kind = 'loan_payment'
    SQL
  end
end
