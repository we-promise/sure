class AddFeeToImportRows < ActiveRecord::Migration[7.2]
  def change
    add_column :import_rows, :fee, :string
  end
end
