class AddTransactionTimestamps < ActiveRecord::Migration[8.1]
  def change
    add_column :entries, :transacted_at, :datetime
    add_index :entries, [ :account_id, :transacted_at ], where: "transacted_at IS NOT NULL"
    # Keep the source text until the user has reviewed and validated the import.
    add_column :import_rows, :transacted_at, :string
  end
end
