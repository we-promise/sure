# Adds opening-lot baseline columns (`original_quantity` and `original_quantity_as_of`)
# without scanning or locking the table for a data backfill. The check constraint
# is added NOT VALID and validated separately so writes are not blocked across
# a full-table scan. Data backfill runs in the next migration in small batches.
class AddOriginalQuantityToHoldingLots < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  CONSTRAINT_NAME = "holding_lots_original_quantity_non_negative"

  def up
    add_column :holding_lots, :original_quantity, :decimal, precision: 34, scale: 18, if_not_exists: true
    add_column :holding_lots, :original_quantity_as_of, :date, if_not_exists: true

    unless check_constraint_exists?(:holding_lots, name: CONSTRAINT_NAME)
      add_check_constraint :holding_lots, "original_quantity >= 0", name: CONSTRAINT_NAME, validate: false
    end

    validate_check_constraint :holding_lots, name: CONSTRAINT_NAME
  end

  def down
    remove_check_constraint :holding_lots, name: CONSTRAINT_NAME, if_exists: true
    remove_column :holding_lots, :original_quantity_as_of, if_exists: true
    remove_column :holding_lots, :original_quantity, if_exists: true
  end
end
