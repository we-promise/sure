class AddBalanceSignOverrideToSimplefinAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :simplefin_accounts, :balance_sign_override, :string
    add_check_constraint :simplefin_accounts,
                         "balance_sign_override IN ('credit', 'debt')",
                         name: "chk_simplefin_accounts_balance_sign_override"
  end
end
