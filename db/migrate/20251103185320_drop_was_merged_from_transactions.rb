class DropWasMergedFromTransactions < ActiveRecord::Migration[7.2]
  def up
    # Column introduced in PR #267 but no longer needed; safe to remove
    if column_exists?(:transactions, :was_merged)
      remove_column :transactions, :was_merged
    end
  end

  def down
    # Recreate the column for rollback compatibility
    unless column_exists?(:transactions, :was_merged)
      add_column :transactions, :was_merged, :boolean
    end
  end
end
