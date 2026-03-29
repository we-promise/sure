class AddUniqueIndexToBinanceAccounts < ActiveRecord::Migration[7.2]
  def change
    add_index :binance_accounts, [ :binance_item_id, :account_type ],
              unique: true,
              name: "index_binance_accounts_on_item_and_type"
  end
end
