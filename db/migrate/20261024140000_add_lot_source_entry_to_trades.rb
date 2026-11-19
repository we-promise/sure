class AddLotSourceEntryToTrades < ActiveRecord::Migration[8.1]
  def change
    add_reference :trades, :lot_source_entry, type: :uuid, foreign_key: { to_table: :entries, on_delete: :nullify }
  end
end
