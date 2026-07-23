class AddApiSecretToTrading212Items < ActiveRecord::Migration[7.2]
  def change
    add_column :trading212_items, :api_secret, :string
  end
end
