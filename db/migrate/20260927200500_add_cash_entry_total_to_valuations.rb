class AddCashEntryTotalToValuations < ActiveRecord::Migration[8.1]
  def change
    add_column :valuations, :cash_entry_total, :decimal, precision: 19, scale: 4
  end
end
