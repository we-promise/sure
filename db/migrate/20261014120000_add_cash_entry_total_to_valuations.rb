# Renumbered from 20260927200000, which upstream also uses. A database that ran
# it under the old number already has the column, so adding it is skipped.
class AddCashEntryTotalToValuations < ActiveRecord::Migration[8.1]
  def change
    add_column :valuations, :cash_entry_total, :decimal, precision: 19, scale: 4, if_not_exists: true
  end
end
