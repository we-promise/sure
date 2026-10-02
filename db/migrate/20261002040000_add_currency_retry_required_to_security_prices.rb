class AddCurrencyRetryRequiredToSecurityPrices < ActiveRecord::Migration[8.1]
  def change
    add_column :security_prices, :currency_retry_required, :boolean, default: false, null: false
  end
end
