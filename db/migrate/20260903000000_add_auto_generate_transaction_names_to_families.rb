class AddAutoGenerateTransactionNamesToFamilies < ActiveRecord::Migration[8.1]
  def change
    add_column :families, :auto_generate_transaction_names, :boolean, default: false, null: false
  end
end
