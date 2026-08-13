class AddPaymentUrlToRecurringTransactions < ActiveRecord::Migration[8.1]
  def change
    add_column :recurring_transactions, :payment_url, :string
  end
end
