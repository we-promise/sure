class CreateExchangeRatePairs < ActiveRecord::Migration[7.2]
  def change
    create_table :exchange_rate_pairs, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :from_currency, null: false
      t.string :to_currency, null: false
      t.date :first_provider_rate_on
      t.string :provider_name
      t.timestamps
    end

    add_index :exchange_rate_pairs,
              [ :from_currency, :to_currency ],
              unique: true,
              name: "index_exchange_rate_pairs_on_pair_unique"
  end
end
