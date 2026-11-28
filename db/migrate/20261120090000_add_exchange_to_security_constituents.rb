class AddExchangeToSecurityConstituents < ActiveRecord::Migration[8.1]
  def change
    # Tickers are not unique across exchanges (7203 on Tokyo and elsewhere, a
    # BP on two venues), so a fund's holding is identified by its ticker and
    # the provider's exchange code. Blank when the provider gives none.
    add_column :security_constituents, :exchange, :string

    remove_index :security_constituents, [ :security_id, :ticker ], unique: true
    add_index :security_constituents, "security_id, ticker, COALESCE(exchange, '')",
              unique: true, name: "index_security_constituents_on_security_ticker_exchange"

    # One DELETE when a security goes, whether or not Rails callbacks run, as
    # security_splits already does.
    remove_foreign_key :security_constituents, :securities
    add_foreign_key :security_constituents, :securities, on_delete: :cascade
  end
end
