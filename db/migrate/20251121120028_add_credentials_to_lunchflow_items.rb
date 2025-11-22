class AddCredentialsToLunchflowItems < ActiveRecord::Migration[7.2]
  def change
    add_column :lunchflow_items, :api_key, :text
    add_column :lunchflow_items, :base_url, :string
  end
end
