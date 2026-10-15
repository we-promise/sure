# frozen_string_literal: true

# Commodities are their own asset class (not securities): an accountable type,
# a family-scoped location list, an item inventory with sales and moves, and a
# dedicated daily price table keyed by commodity code (XAU, XAG, XPT, ...).
class CreateCommodities < ActiveRecord::Migration[8.1]
  def change
    create_table :commodities, id: :uuid do |t|
      t.string :subtype
      t.jsonb :locked_attributes, default: {}
      t.timestamps
    end

    create_table :commodity_prices, id: :uuid do |t|
      t.string :code, null: false
      t.date :date, null: false
      t.decimal :price, precision: 19, scale: 6, null: false # per troy ounce
      t.string :currency, null: false, default: "USD"
      t.string :source, null: false
      t.boolean :provisional, null: false, default: false
      t.timestamps

      t.index %i[code date currency], unique: true
      t.check_constraint "price > 0", name: "chk_commodity_prices_price_positive"
    end

    create_table :commodity_locations, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.timestamps

      t.index "family_id, lower((name)::text)", unique: true, name: "index_commodity_locations_on_family_and_lower_name"
    end

    create_table :commodity_items, id: :uuid do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :location, foreign_key: { to_table: :commodity_locations, on_delete: :nullify }, type: :uuid
      t.string :code, null: false
      t.string :name, null: false
      t.string :form, null: false, default: "bar"
      t.integer :quantity, null: false, default: 1
      t.integer :remaining_quantity, null: false, default: 1
      t.decimal :gross_weight_grams, precision: 24, scale: 10, null: false # per piece
      t.string :weight_unit, null: false, default: "g" # unit the weight was entered in
      t.decimal :fineness, precision: 6, scale: 5, null: false
      t.string :serial_number
      t.string :manufacturer
      t.integer :year
      t.string :dealer
      t.text :notes

      t.date :purchase_date, null: false
      t.string :purchase_currency, null: false
      t.decimal :metal_cost, precision: 19, scale: 4, null: false, default: 0
      t.decimal :premium, precision: 19, scale: 4, null: false, default: 0
      t.decimal :vat, precision: 19, scale: 4, null: false, default: 0
      t.decimal :shipping, precision: 19, scale: 4, null: false, default: 0
      t.decimal :insurance, precision: 19, scale: 4, null: false, default: 0

      t.string :sell_back_mode # spot_percent | per_piece
      t.decimal :sell_back_value, precision: 19, scale: 4
      t.timestamps

      t.index %i[account_id code]
      t.check_constraint "form IN ('bar', 'coin', 'round', 'granules', 'other')", name: "chk_commodity_items_form"
      t.check_constraint "weight_unit IN ('g', 'ozt')", name: "chk_commodity_items_weight_unit"
      t.check_constraint "quantity >= 1 AND remaining_quantity >= 0 AND remaining_quantity <= quantity", name: "chk_commodity_items_quantity"
      t.check_constraint "gross_weight_grams > 0", name: "chk_commodity_items_weight_positive"
      t.check_constraint "fineness > 0 AND fineness <= 1", name: "chk_commodity_items_fineness"
      t.check_constraint "sell_back_mode IS NULL OR sell_back_mode IN ('spot_percent', 'per_piece')", name: "chk_commodity_items_sell_back_mode"
    end

    create_table :commodity_sales, id: :uuid do |t|
      t.references :item, null: false, foreign_key: { to_table: :commodity_items, on_delete: :cascade }, type: :uuid
      t.date :date, null: false
      t.integer :quantity, null: false
      t.decimal :proceeds, precision: 19, scale: 4, null: false # total for all pieces sold
      t.decimal :costs, precision: 19, scale: 4, null: false, default: 0
      t.string :currency, null: false
      t.timestamps

      t.check_constraint "quantity >= 1", name: "chk_commodity_sales_quantity"
    end

    create_table :commodity_item_moves, id: :uuid do |t|
      t.references :item, null: false, foreign_key: { to_table: :commodity_items, on_delete: :cascade }, type: :uuid
      t.references :from_location, foreign_key: { to_table: :commodity_locations, on_delete: :nullify }, type: :uuid
      t.references :to_location, foreign_key: { to_table: :commodity_locations, on_delete: :nullify }, type: :uuid
      t.date :moved_on, null: false
      t.timestamps
    end
  end
end
