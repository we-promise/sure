class AddTransactedAtToEntries < ActiveRecord::Migration[7.2]
  def change
    add_column :entries, :transacted_at, :datetime, null: true
  end
end
