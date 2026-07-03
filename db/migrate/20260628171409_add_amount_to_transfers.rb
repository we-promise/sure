class AddAmountToTransfers < ActiveRecord::Migration[8.1]
  def change
    add_column :transfers, :amount, :decimal, precision: 19, scale: 4, null: false, default: "0.0"

    reversible do |dir|
      dir.up do
        # Backfill principal from outflow entries: amount = outflow_entry.amount - source_fee_amount
        execute <<~SQL
          UPDATE transfers
          SET amount = e.amount - COALESCE(transfers.source_fee_amount, 0)
          FROM entries e
          WHERE e.entryable_id = transfers.outflow_transaction_id
            AND e.entryable_type = 'Transaction';
        SQL
      end
    end

    add_check_constraint :transfers, "amount >= 0::numeric", name: "check_transfer_amount_non_negative"
  end
end
