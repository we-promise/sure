class AddQuotedDirectlyToExchangeRatePairs < ActiveRecord::Migration[8.1]
  def change
    add_column :exchange_rate_pairs, :quoted_directly, :boolean, default: false, null: false
  end
end
