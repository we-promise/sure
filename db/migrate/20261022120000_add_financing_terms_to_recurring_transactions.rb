class AddFinancingTermsToRecurringTransactions < ActiveRecord::Migration[8.1]
  def change
    add_column :recurring_transactions, :financed_principal_amount, :decimal, precision: 19, scale: 4
    add_column :recurring_transactions, :financed_interest_rate, :decimal, precision: 10, scale: 3
    add_column :recurring_transactions, :financed_source_entry_id, :uuid

    add_index :recurring_transactions, :financed_source_entry_id
    add_foreign_key :recurring_transactions, :entries,
                     column: :financed_source_entry_id,
                     on_delete: :nullify

    add_column :recurring_transactions, :financed_interest_category_id, :uuid
    add_index :recurring_transactions, :financed_interest_category_id
    add_foreign_key :recurring_transactions, :categories,
                     column: :financed_interest_category_id,
                     on_delete: :nullify
  end
end
