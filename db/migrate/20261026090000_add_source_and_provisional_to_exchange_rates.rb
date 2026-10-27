# Bullion quotes are stored as XAU/XAG/XPT/XPD exchange rates. `source` records
# which provider supplied a row; `provisional` marks an intraday quote or a
# futures value that a later close should replace (see security_prices).
class AddSourceAndProvisionalToExchangeRates < ActiveRecord::Migration[8.1]
  def change
    add_column :exchange_rates, :source, :string
    add_column :exchange_rates, :provisional, :boolean, null: false, default: false
  end
end
