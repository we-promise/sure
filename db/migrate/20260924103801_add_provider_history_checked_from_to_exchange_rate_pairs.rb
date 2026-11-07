class AddProviderHistoryCheckedFromToExchangeRatePairs < ActiveRecord::Migration[8.1]
  # Persist a separate verified-history boundary without requiring existing rows to backfill.
  def change
    add_column :exchange_rate_pairs, :provider_history_checked_from, :date
  end
end
