class AddProviderHistoryCheckedFromToExchangeRatePairs < ActiveRecord::Migration[8.1]
  def change
    add_column :exchange_rate_pairs, :provider_history_checked_from, :date
  end
end
