class AddExternalIdToImports < ActiveRecord::Migration[7.2]
  def change
    add_column :imports, :external_id_col_label, :string
    add_column :import_rows, :external_id, :string
  end
end
