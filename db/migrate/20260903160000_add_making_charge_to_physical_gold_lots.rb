class AddMakingChargeToPhysicalGoldLots < ActiveRecord::Migration[8.0]
  def change
    add_column :physical_gold_lots, :making_charge, :decimal, precision: 18, scale: 2
    add_check_constraint :physical_gold_lots, "making_charge IS NULL OR making_charge >= 0", name: "physical_gold_lots_making_charge_nonnegative"
  end
end
