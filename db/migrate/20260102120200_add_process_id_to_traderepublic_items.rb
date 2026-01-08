class AddProcessIdToTraderepublicItems < ActiveRecord::Migration[7.2]
  def change
    add_column :traderepublic_items, :process_id, :string
    add_column :traderepublic_items, :session_token, :string
    add_column :traderepublic_items, :refresh_token, :string
    add_column :traderepublic_items, :session_cookies, :jsonb
  end
end
