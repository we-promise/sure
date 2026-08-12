class AddMerchantColumnsToImportRows < ActiveRecord::Migration[7.2]
  def change
    add_column :import_rows, :merchant_color, :string
    add_column :import_rows, :merchant_website, :string
  end
end
