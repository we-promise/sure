class AddImportAllHistoryToWiseItems < ActiveRecord::Migration[7.2]
  def change
    add_column :wise_items, :import_all_history, :boolean, default: false, null: false
  end
end
