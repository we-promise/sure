class AddGusInflationRatesAndAutoFetchToBondLots < ActiveRecord::Migration[7.2]
  def change
    create_table :gus_inflation_rates, id: :uuid do |t|
      t.integer :year, null: false
      t.integer :month, null: false
      t.decimal :rate_yoy, precision: 8, scale: 4, null: false
      t.string :source, null: false, default: "sdp"

      t.timestamps
    end

    add_index :gus_inflation_rates, %i[year month], unique: true
  end
end
