class AddRefundOfToTransactions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_transactions_on_refund_of_id"

  def up
    add_column :transactions, :refund_of_id, :uuid unless column_exists?(:transactions, :refund_of_id)

    unless valid_index_exists?
      # An interrupted concurrent build can leave an INVALID index. Remove it
      # before retrying rather than treating its catalog entry as a usable index.
      execute "DROP INDEX CONCURRENTLY IF EXISTS #{INDEX_NAME}"
      add_index :transactions, :refund_of_id, name: INDEX_NAME, algorithm: :concurrently
    end

    # Keep the table scan out of the lock taken by ADD FOREIGN KEY. Validation
    # runs in the following migration after this statement has committed.
    unless foreign_key_exists?(:transactions, :transactions, column: :refund_of_id)
      add_foreign_key :transactions, :transactions,
        column: :refund_of_id, on_delete: :nullify, validate: false
    end
  end

  def down
    remove_foreign_key :transactions, :transactions, column: :refund_of_id, if_exists: true
    remove_index :transactions, name: INDEX_NAME, if_exists: true, algorithm: :concurrently
    remove_column :transactions, :refund_of_id, if_exists: true
  end

  private
    def valid_index_exists?
      select_value(<<~SQL.squish) == true
        SELECT indisvalid FROM pg_index
        WHERE indrelid = 'transactions'::regclass
          AND indexrelid = to_regclass('#{INDEX_NAME}')
      SQL
    end
end
