class CreateInflationRates < ActiveRecord::Migration[7.2]
  def change
    create_table :inflation_rates, id: :uuid do |t|
      t.string :source, null: false
      t.integer :year, null: false
      t.integer :month, null: false
      t.decimal :rate_yoy, precision: 8, scale: 4, null: false

      t.timestamps
    end

    add_index :inflation_rates, %i[source year month], unique: true
  end
end
