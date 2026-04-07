class AddExchangePortfolioFieldsToCoinstatsItems < ActiveRecord::Migration[7.2]
  def change
    add_column :coinstats_items, :exchange_portfolio_id, :string
    add_column :coinstats_items, :exchange_connection_id, :string

    add_index :coinstats_items, [ :family_id, :exchange_portfolio_id ],
              unique: true,
              where: "exchange_portfolio_id IS NOT NULL"
    add_index :coinstats_items, :exchange_connection_id
  end
end
