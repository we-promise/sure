class AddSourceFilenameToImports < ActiveRecord::Migration[8.1]
  def change
    add_column :imports, :source_filename, :string
  end
end
