class AddDescriptionToPhysicalGoldLots < ActiveRecord::Migration[7.2]
  def change
    add_column :physical_gold_lots, :description, :string
  end
end
