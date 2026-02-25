class AddDownPaymentToLoans < ActiveRecord::Migration[7.2]
  def change
    add_column :loans, :down_payment, :decimal
  end
end
