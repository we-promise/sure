# frozen_string_literal: true

class IncreaseEntryAmountPrecision < ActiveRecord::Migration[8.1]
  COLUMNS = {
    entries: { column: :amount, options: { null: false } },
    accounts: { column: :balance, options: {} },
    transfers: { column: :amount, options: { default: 0.0, null: false } }
  }.freeze

  def up
    COLUMNS.each do |table, definition|
      change_column table, definition[:column], :decimal, precision: 34, scale: 18, **definition[:options]
    end
  end

  def down
    if COLUMNS.any? { |table, definition| excess_precision?(table, definition[:column]) }
      raise ActiveRecord::IrreversibleMigration,
        "Reducing transaction amounts to four decimal places would discard stored cryptocurrency precision"
    end

    COLUMNS.each do |table, definition|
      change_column table, definition[:column], :decimal, precision: 19, scale: 4, **definition[:options]
    end
  end

  private
    def excess_precision?(table, column)
      connection.select_value(
        "SELECT 1 FROM #{table} WHERE #{column} IS NOT NULL AND #{column} <> round(#{column}, 4) LIMIT 1"
      ).present?
    end
end
