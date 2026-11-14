class AddIndexOnExchangeRatesUpdatedAt < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :exchange_rates, :updated_at, algorithm: :concurrently, if_not_exists: true
  end
end
