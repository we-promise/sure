class AddMerchantToPhysicalGoldLots < ActiveRecord::Migration[7.2]
  def change
    add_reference :physical_gold_lots, :merchant, type: :uuid, foreign_key: { on_delete: :nullify }
  end
end
