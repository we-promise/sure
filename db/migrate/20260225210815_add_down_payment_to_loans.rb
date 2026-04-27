class AddDownPaymentToLoans < ActiveRecord::Migration[7.2]
  def change
    add_column :loans, :down_payment, :decimal, precision: 15, scale: 2
    add_check_constraint :loans,
      "down_payment IS NULL OR down_payment >= 0",
      name: "chk_loans_down_payment_non_negative"
  end
end
