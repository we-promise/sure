class AddAmountFormatToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :amount_format, :string, default: "language", null: false
    add_check_constraint :users,
      "amount_format IN ('language', 'international', 'indian', 'european')",
      name: "chk_users_amount_format"
  end
end
