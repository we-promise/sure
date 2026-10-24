class AddCurrencyRetryGeneratedToSecurityPrices < ActiveRecord::Migration[8.1]
  # Separate generated fallback ownership from recovery eligibility on manual quotes.
  def change
    add_column :security_prices, :currency_retry_generated, :boolean, default: false, null: false
  end
end
