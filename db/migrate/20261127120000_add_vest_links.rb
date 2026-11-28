# A vest is recorded as several entries entered together: the shares, the
# gross income they were, and the taxes withheld from it. vest_entry_id links
# the income and tax entries to the vest's own entry, so they are edited and
# deleted as one. units_withheld holds the shares a stock plan kept back for
# the taxes; they never reach the account, so they are not in the trade's qty.
class AddVestLinks < ActiveRecord::Migration[8.1]
  def change
    add_reference :entries, :vest_entry, type: :uuid, foreign_key: { to_table: :entries, on_delete: :cascade }, index: true
    add_column :trades, :units_withheld, :decimal, precision: 34, scale: 18
  end
end
