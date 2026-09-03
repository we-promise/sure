class AddDescriptionToPhysicalGoldLots < ActiveRecord::Migration[8.0]
  def change
    add_column :physical_gold_lots, :description, :string
  end
end
