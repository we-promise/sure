class AddDownPaymentToLoans < ActiveRecord::Migration[7.2]
  def change
    add_column :loans, :down_payment, :decimal, precision: 15, scale: 2
  end
end
