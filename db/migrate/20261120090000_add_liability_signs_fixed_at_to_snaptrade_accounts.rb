class AddLiabilitySignsFixedAtToSnaptradeAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :snaptrade_accounts, :liability_signs_fixed_at, :datetime
  end
end
