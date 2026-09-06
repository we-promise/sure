class AddScaPrivateKeyToWiseItems < ActiveRecord::Migration[7.2]
  def change
    add_column :wise_items, :sca_private_key, :text
  end
end
