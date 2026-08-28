class AddBalanceSignOverrideToSimplefinAccounts < ActiveRecord::Migration[8.0]
  def change
    add_column :simplefin_accounts, :balance_sign_override, :string
  end
end
