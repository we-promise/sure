class AddBalanceDateToSimplefinAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :simplefin_accounts, :balance_date, :datetime
  end
end
