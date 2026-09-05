class NullifyDeletedMerchantsOnPhysicalGoldLots < ActiveRecord::Migration[7.2]
  def up
    remove_foreign_key :physical_gold_lots, :merchants
    add_foreign_key :physical_gold_lots, :merchants, on_delete: :nullify
  end

  def down
    remove_foreign_key :physical_gold_lots, :merchants
    add_foreign_key :physical_gold_lots, :merchants, on_delete: :nullify
  end
end
