class AddManualTotalCostToHoldingLots < ActiveRecord::Migration[8.1]
  def change
    add_column :holding_lots, :manual_total_cost, :decimal, precision: 19, scale: 4
    add_check_constraint :holding_lots, "manual_total_cost >= 0", name: "holding_lots_manual_total_cost_non_negative"
  end
end
