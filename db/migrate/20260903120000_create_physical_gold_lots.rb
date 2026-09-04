class CreatePhysicalGoldLots < ActiveRecord::Migration[7.2]
  def change
    create_table :physical_gold_lots, id: :uuid do |t|
      t.references :account, null: false, type: :uuid, foreign_key: true
      t.date :acquired_on, null: false
      t.decimal :weight, precision: 18, scale: 6, null: false
      t.string :weight_unit, null: false
      t.decimal :karat, precision: 4, scale: 1, null: false
      t.decimal :cost_amount, precision: 18, scale: 2
      t.string :currency
      t.text :notes
      t.timestamps
    end

    add_check_constraint :physical_gold_lots, "weight > 0", name: "physical_gold_lots_weight_positive"
    add_check_constraint :physical_gold_lots, "weight_unit IN ('gram', 'troy_ounce', 'kilogram')", name: "physical_gold_lots_weight_unit_valid"
    add_check_constraint :physical_gold_lots, "karat > 0 AND karat <= 24", name: "physical_gold_lots_karat_valid"
    add_check_constraint :physical_gold_lots, "cost_amount IS NULL OR cost_amount >= 0", name: "physical_gold_lots_cost_amount_nonnegative"
  end
end
