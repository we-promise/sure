class AddPurchaseFieldsToBondLots < ActiveRecord::Migration[7.2]
  def change
    add_column :bond_lots, :subtype, :string
    add_column :bond_lots, :rate_type, :string
    add_column :bond_lots, :coupon_frequency, :string
    add_reference :bond_lots, :entry, type: :uuid, foreign_key: true

    add_index :bond_lots, :subtype
  end
end
