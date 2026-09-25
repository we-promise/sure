class AddMerchantColumnToImports < ActiveRecord::Migration[8.1]
  def change
    add_column :imports, :merchant_col_label, :string
  end
end
