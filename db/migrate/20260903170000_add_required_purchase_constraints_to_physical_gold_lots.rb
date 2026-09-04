class AddRequiredPurchaseConstraintsToPhysicalGoldLots < ActiveRecord::Migration[7.2]
  def up
    change_column_null :physical_gold_lots, :cost_amount, false
    add_check_constraint :physical_gold_lots,
                         "description IS NOT NULL AND btrim(description) <> ''",
                         name: "physical_gold_lots_description_present"
  end

  def down
    remove_check_constraint :physical_gold_lots, name: "physical_gold_lots_description_present"
    change_column_null :physical_gold_lots, :cost_amount, true
  end
end
