class AddPositionsFileStrToImports < ActiveRecord::Migration[7.2]
  def change
    add_column :imports, :positions_file_str, :text
  end
end
