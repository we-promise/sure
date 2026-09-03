class AddMerchantToPhysicalGoldLots < ActiveRecord::Migration[8.0]
  def change
    add_reference :physical_gold_lots, :merchant, type: :uuid, foreign_key: true
  end
end
