class RemoveLegacyBondLotInflationSourceColumns < ActiveRecord::Migration[7.2]
  def up
    remove_index :bond_lots, :inflation_provider, if_exists: true

    remove_column :bond_lots, :auto_fetch_inflation, :boolean, if_exists: true
    remove_column :bond_lots, :inflation_provider, :string, if_exists: true
  end

  def down
    add_column :bond_lots, :auto_fetch_inflation, :boolean, null: false, default: true, if_not_exists: true
    add_column :bond_lots, :inflation_provider, :string, if_not_exists: true

    add_index :bond_lots, :inflation_provider, if_not_exists: true
  end
end
