class AddMaturitySettlementFieldsToBondLots < ActiveRecord::Migration[7.2]
  def change
    add_column :bond_lots, :auto_close_on_maturity, :boolean, default: true, null: false
    add_column :bond_lots, :closed_on, :date
    add_column :bond_lots, :settlement_amount, :decimal, precision: 19, scale: 4
    add_column :bond_lots, :tax_withheld, :decimal, precision: 19, scale: 4
    add_column :bond_lots, :tax_strategy, :string, default: "standard", null: false
    add_column :bond_lots, :tax_rate, :decimal, precision: 6, scale: 3, default: 19.0, null: false

    add_index :bond_lots, :closed_on
    add_index :bond_lots, [ :bond_id, :closed_on ]
  end
end
