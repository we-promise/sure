class AddIncludeRawDataToLunchflowItems < ActiveRecord::Migration[8.1]
  def change
    add_column :lunchflow_items, :include_raw_data, :boolean, default: false, null: false
  end
end
