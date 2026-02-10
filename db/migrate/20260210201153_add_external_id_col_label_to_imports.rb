class AddExternalIdColLabelToImports < ActiveRecord::Migration[7.2]
  def change
    add_column :imports, :external_id_col_label, :string
  end
end
