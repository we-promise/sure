class CreateHoldingLots < ActiveRecord::Migration[8.1]
  def change
    create_table :holding_lots, id: :uuid do |t|
      t.references :account, null: false, type: :uuid, index: false, foreign_key: { on_delete: :cascade }
      t.references :security, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      # The trade that acquired the lot; nil for the opening lot.
      t.references :source_entry, type: :uuid, foreign_key: { to_table: :entries, on_delete: :cascade }
      # The security an opening lot was opened under, so a reset can return it.
      t.references :origin_security, type: :uuid, foreign_key: { to_table: :securities, on_delete: :nullify }
      t.date :acquired_on
      t.decimal :qty, precision: 34, scale: 18, null: false
      t.decimal :unit_cost, precision: 19, scale: 10
      t.string :currency, null: false
      # The provider reported fewer units than the trades add up to.
      t.boolean :clamped, null: false, default: false
      t.timestamps
    end

    add_index :holding_lots, %i[account_id source_entry_id], unique: true
    add_index :holding_lots, %i[account_id security_id], unique: true, where: "source_entry_id IS NULL",
      name: "index_holding_lots_one_opening_lot_per_position"
    add_check_constraint :holding_lots, "qty >= 0", name: "holding_lots_qty_non_negative"
  end
end
