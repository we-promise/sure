class CreatePreciousMetals < ActiveRecord::Migration[8.1]
  def change
    create_table :precious_metals, id: :uuid do |t|
      t.string :metal_type, null: false, default: "gold"
      t.string :subtype
      t.jsonb :locked_attributes, null: false, default: {}
      t.boolean :valuation_pending, null: false, default: false
      t.datetime :valued_at
      t.timestamps
      t.check_constraint "metal_type = 'gold'", name: "precious_metals_supported_metal"
    end

    create_table :precious_metal_lots, id: :uuid do |t|
      t.references :precious_metal, null: false, type: :uuid, foreign_key: true
      t.references :merchant, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :description, null: false
      t.date :acquired_on, null: false
      t.decimal :weight, precision: 19, scale: 6, null: false
      t.string :weight_unit, null: false
      t.decimal :karat, precision: 6, scale: 3, null: false
      t.decimal :cost_amount, precision: 19, scale: 4, null: false
      t.decimal :making_charge, precision: 19, scale: 4
      t.decimal :manual_value, precision: 19, scale: 4
      t.string :currency, null: false
      t.text :notes
      t.timestamps
      t.check_constraint "btrim(description) <> ''", name: "precious_metal_lots_description_present"
      t.check_constraint "weight > 0", name: "precious_metal_lots_positive_weight"
      t.check_constraint "weight_unit IN ('gram', 'troy_ounce', 'kilogram')", name: "precious_metal_lots_weight_unit"
      t.check_constraint "karat > 0 AND karat <= 24", name: "precious_metal_lots_karat"
      t.check_constraint "cost_amount >= 0", name: "precious_metal_lots_cost"
      t.check_constraint "making_charge >= 0", name: "precious_metal_lots_making_charge"
      t.check_constraint "manual_value >= 0", name: "precious_metal_lots_manual_value"
    end
  end
end
