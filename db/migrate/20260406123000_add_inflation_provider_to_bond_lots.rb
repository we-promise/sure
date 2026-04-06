class AddInflationProviderToBondLots < ActiveRecord::Migration[7.2]
  def up
    add_column :bond_lots, :inflation_provider, :string
    add_index :bond_lots, :inflation_provider

    execute <<~SQL
      UPDATE bond_lots
      SET inflation_provider = 'gus_sdp'
      WHERE subtype IN ('inflation_linked', 'savings') AND auto_fetch_inflation = TRUE
    SQL
  end

  def down
    remove_index :bond_lots, :inflation_provider
    remove_column :bond_lots, :inflation_provider
  end
end
