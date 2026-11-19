class AddQuotedDirectlyToExchangeRatePairs < ActiveRecord::Migration[8.1]
  # Not backfilled from first_provider_rate_on: a recorded quote may be one the
  # provider no longer gives, such as Yahoo's mis-scaled RUBGEL=X, which is
  # rejected. Pairs it still quotes are flagged on their next successful fetch.
  def change
    add_column :exchange_rate_pairs, :quoted_directly, :boolean, default: false, null: false
  end
end
