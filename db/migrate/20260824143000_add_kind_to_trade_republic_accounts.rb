class AddKindToTradeRepublicAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :trade_republic_accounts, :kind, :string, null: false, default: "portfolio"
    add_index :trade_republic_accounts, [ :trade_republic_item_id, :kind ]
  end
end
