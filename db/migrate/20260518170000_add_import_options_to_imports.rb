class AddImportOptionsToImports < ActiveRecord::Migration[7.2]
  def change
    add_column :imports, :import_options, :jsonb, null: false, default: {}
  end
end
