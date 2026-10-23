class AddBalanceSignOverrideToSophtronAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :sophtron_accounts, :balance_sign_override, :string
    add_check_constraint :sophtron_accounts,
                         "balance_sign_override IN ('credit', 'debt')",
                         name: "chk_sophtron_accounts_balance_sign_override"
  end
end
