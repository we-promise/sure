class AddAmountFormatToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :amount_format, :string, default: "language", null: false
    # Add the constraint without a full-table scan. The next migration
    # validates existing rows under a lighter lock.
    add_check_constraint :users,
      "amount_format IN ('language', 'international', 'indian', 'european')",
      name: "chk_users_amount_format",
      validate: false
  end
end
