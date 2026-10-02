class AddMerchantToTransactionImports < ActiveRecord::Migration[8.1]
  def change
    add_column :imports, :merchant_col_label, :string
    add_column :import_rows, :merchant, :string
  end
end
