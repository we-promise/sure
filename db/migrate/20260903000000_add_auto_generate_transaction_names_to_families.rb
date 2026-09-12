class AddAutoGenerateTransactionNamesToFamilies < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :auto_generate_transaction_names, :boolean, default: false, null: false
  end
end
