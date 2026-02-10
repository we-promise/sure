class AddExternalIdToImportRows < ActiveRecord::Migration[7.2]
  def change
    add_column :import_rows, :external_id, :string
    add_index :import_rows, :external_id
  end
end
