class AddSubtypeToAccountables < ActiveRecord::Migration[7.2]
  def change
    add_column :depositories, :subtype, :string
    add_column :investments, :subtype, :string
    add_column :loans, :subtype, :string
    add_column :credit_cards, :subtype, :string
    add_column :other_assets, :subtype, :string
    add_column :other_liabilities, :subtype, :string
    add_column :properties, :subtype, :string
    add_column :vehicles, :subtype, :string
    add_column :cryptos, :subtype, :string
  end
end
