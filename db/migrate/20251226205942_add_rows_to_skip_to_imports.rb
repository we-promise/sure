class AddRowsToSkipToImports < ActiveRecord::Migration[7.2]
  def change
    add_column :imports, :rows_to_skip, :integer, default: 0, null: false
  end
end
