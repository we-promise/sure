class AddQuotedDirectlyToExchangeRatePairs < ActiveRecord::Migration[8.1]
  def change
    add_column :exchange_rate_pairs, :quoted_directly, :boolean, default: false, null: false

    # Nothing derived rates before this column existed, so a pair with a
    # provider rate on record was quoted by the provider itself.
    up_only do
      execute "UPDATE exchange_rate_pairs SET quoted_directly = TRUE WHERE first_provider_rate_on IS NOT NULL"
    end
  end
end
