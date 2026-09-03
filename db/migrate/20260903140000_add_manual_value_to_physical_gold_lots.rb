class AddManualValueToPhysicalGoldLots < ActiveRecord::Migration[8.0]
  def change
    add_column :physical_gold_lots, :manual_value, :decimal, precision: 18, scale: 2
    add_check_constraint :physical_gold_lots, "manual_value IS NULL OR manual_value >= 0", name: "physical_gold_lots_manual_value_nonnegative"
  end
end
