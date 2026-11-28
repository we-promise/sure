class AddCashEntryTotalToValuations < ActiveRecord::Migration[8.1]
  def up
    add_column :valuations, :cash_entry_total, :decimal, precision: 19, scale: 4, if_not_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "cash_entry_total may already have contained ledger baselines before this migration"
  end
end
