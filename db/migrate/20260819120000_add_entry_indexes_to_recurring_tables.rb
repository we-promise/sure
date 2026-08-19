class AddEntryIndexesToRecurringTables < ActiveRecord::Migration[8.1]
  def change
    # Entry deletes enforce cascade/nullify on these tables; without a
    # leading entry_id index each delete walks the whole table.
    add_index :recurring_match_rejections, :entry_id
    add_index :recurring_price_changes, :entry_id
  end
end
