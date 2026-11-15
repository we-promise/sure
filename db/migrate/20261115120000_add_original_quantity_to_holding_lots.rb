class AddOriginalQuantityToHoldingLots < ActiveRecord::Migration[8.1]
  def up
    add_column :holding_lots, :original_quantity, :decimal, precision: 34, scale: 18
    add_check_constraint :holding_lots, "original_quantity >= 0", name: "holding_lots_original_quantity_non_negative"

    # Backfill original_quantity for historical opening lots:
    # Original quantity is remaining qty plus recorded disposals taken from the opening lot (lot_source_entry_id IS NULL).
    # Clamped positions (clamped: true) are excluded as their shortfalls do not represent opening lots.
    execute <<~SQL
      UPDATE holding_lots hl
      SET original_quantity = hl.qty + COALESCE((
        SELECT SUM(d.qty)
        FROM holding_lot_disposals d
        JOIN entries e ON e.id = d.sale_entry_id
        JOIN trades t ON t.id = e.entryable_id AND e.entryable_type = 'Trade'
        WHERE d.account_id = hl.account_id
          AND d.lot_source_entry_id IS NULL
          AND t.security_id = hl.security_id
      ), 0)
      WHERE hl.source_entry_id IS NULL AND hl.clamped = false;
    SQL
  end

  def down
    remove_check_constraint :holding_lots, name: "holding_lots_original_quantity_non_negative"
    remove_column :holding_lots, :original_quantity
  end
end
