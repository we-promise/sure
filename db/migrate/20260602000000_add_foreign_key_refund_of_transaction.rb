class AddForeignKeyRefundOfTransaction < ActiveRecord::Migration[7.2]
  def change
    nullify_orphaned_refund_links
    add_foreign_key :transactions, :transactions,
                    column: :refund_of_transaction_id,
                    on_delete: :nullify,
                    validate: true
  end

  private

    def nullify_orphaned_refund_links
      # One-off cleanup: orphaned refund_of_transaction_id values that point to
      # deleted transactions must be nullified before adding the FK constraint.
      execute <<~SQL.squish
        UPDATE transactions
        SET refund_of_transaction_id = NULL
        WHERE refund_of_transaction_id IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM transactions t2
            WHERE t2.id = transactions.refund_of_transaction_id
          )
      SQL
    end
end
