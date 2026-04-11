class AddPsuTypeToEnableBankingItems < ActiveRecord::Migration[7.2]
  def change
    add_column :enable_banking_items, :psu_type, :string
  end
end
