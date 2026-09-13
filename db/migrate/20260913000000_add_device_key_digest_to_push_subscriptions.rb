class AddDeviceKeyDigestToPushSubscriptions < ActiveRecord::Migration[7.2]
  def change
    add_column :push_subscriptions, :device_key_digest, :string
  end
end
