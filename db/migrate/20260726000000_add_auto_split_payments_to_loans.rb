class AddAutoSplitPaymentsToLoans < ActiveRecord::Migration[7.2]
  def change
    add_column :loans, :auto_split_payments, :boolean, default: false, null: false
  end
end
