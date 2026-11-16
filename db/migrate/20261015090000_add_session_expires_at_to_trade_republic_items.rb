class AddSessionExpiresAtToTradeRepublicItems < ActiveRecord::Migration[8.1]
  def change
    add_column :trade_republic_items, :session_expires_at, :datetime
  end
end
