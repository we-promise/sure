class RefactorMobileDeviceOauth < ActiveRecord::Migration[7.2]
  def change
    add_column :oauth_access_tokens, :mobile_device_id, :uuid
    add_index :oauth_access_tokens, :mobile_device_id
    remove_column :mobile_devices, :oauth_application_id, :integer
  end
end
