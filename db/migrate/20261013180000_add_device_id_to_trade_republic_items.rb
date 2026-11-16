class AddDeviceIdToTradeRepublicItems < ActiveRecord::Migration[8.1]
  def change
    # A volatile default gives every existing row its own device ID.
    add_column :trade_republic_items, :device_id, :uuid, default: -> { "gen_random_uuid()" }, null: false
  end
end
