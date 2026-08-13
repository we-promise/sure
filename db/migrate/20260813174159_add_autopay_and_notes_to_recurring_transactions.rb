class AddAutopayAndNotesToRecurringTransactions < ActiveRecord::Migration[8.1]
  def change
    add_column :recurring_transactions, :autopay, :boolean, default: false, null: false
    add_column :recurring_transactions, :notes, :text
  end
end
