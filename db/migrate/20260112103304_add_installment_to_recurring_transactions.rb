class AddInstallmentToRecurringTransactions < ActiveRecord::Migration[7.2]
  def change
    add_reference :recurring_transactions, :installment, foreign_key: true, type: :uuid, index: true
  end
end
