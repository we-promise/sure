class AddPriceProviderToSecurities < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    add_column :securities, :price_provider, :string
    add_index :securities, :price_provider, algorithm: :concurrently
  end
end
