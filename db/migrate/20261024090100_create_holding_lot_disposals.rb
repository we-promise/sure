class CreateHoldingLotDisposals < ActiveRecord::Migration[8.1]
  def change
    create_table :holding_lot_disposals, id: :uuid do |t|
      t.references :account, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :sale_entry, null: false, type: :uuid, foreign_key: { to_table: :entries, on_delete: :cascade }
      # The trade that acquired the lot consumed; nil for the opening lot and
      # for units sold beyond what was held.
      t.references :lot_source_entry, type: :uuid, index: false, foreign_key: { to_table: :entries, on_delete: :nullify }
      t.decimal :qty, precision: 34, scale: 18, null: false
      t.decimal :unit_cost, precision: 19, scale: 10
      t.string :currency, null: false
      t.timestamps
    end

    add_check_constraint :holding_lot_disposals, "qty > 0", name: "holding_lot_disposals_qty_positive"
  end
end
