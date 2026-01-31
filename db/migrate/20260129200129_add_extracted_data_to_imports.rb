class AddExtractedDataToImports < ActiveRecord::Migration[7.2]
  def change
    add_column :imports, :extracted_data, :jsonb
  end
end
