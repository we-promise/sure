class AddDebitAndCreditColLabelsToImports < ActiveRecord::Migration[8.1]
  def change
    add_column :imports, :debit_col_label, :string
    add_column :imports, :credit_col_label, :string
  end
end
