class NullifyDeletedMerchantsOnPhysicalGoldLots < ActiveRecord::Migration[7.2]
  def change
    remove_foreign_key :physical_gold_lots, :merchants
    add_foreign_key :physical_gold_lots, :merchants, on_delete: :nullify
  end
end
