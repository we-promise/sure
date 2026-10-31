# A database that ran this column from #3753 under an earlier migration number
# already has it, so adding it is skipped.
class AddCashEntryTotalToValuations < ActiveRecord::Migration[8.1]
  def change
    add_column :valuations, :cash_entry_total, :decimal, precision: 19, scale: 4, if_not_exists: true
  end
end
