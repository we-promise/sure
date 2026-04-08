class CreateIndianInvestmentAccountables < ActiveRecord::Migration[7.2]
  def change
    create_table :indian_fixed_investments, id: :uuid do |t|
      t.timestamps
      t.jsonb :locked_attributes
      t.string :subtype
      t.decimal :interest_rate, precision: 5, scale: 2
      t.date :maturity_date
      t.decimal :deposit_amount, precision: 19, scale: 4
      t.string :deposit_frequency, default: "monthly"
    end

    create_table :indian_gold_investments, id: :uuid do |t|
      t.timestamps
      t.jsonb :locked_attributes
      t.string :subtype
      t.decimal :quantity_grams, precision: 10, scale: 4
      t.string :purity
      t.decimal :purchase_price_per_gram, precision: 19, scale: 2
      t.string :weight_unit, default: "grams"
    end

    create_table :indian_real_estates, id: :uuid do |t|
      t.timestamps
      t.jsonb :locked_attributes
      t.string :subtype
      t.decimal :area_value, precision: 19, scale: 4
      t.string :area_unit, default: "sqft"
      t.string :registration_number
      t.string :property_type_classification
    end

    create_table :indian_bonds, id: :uuid do |t|
      t.timestamps
      t.jsonb :locked_attributes
      t.string :subtype
      t.decimal :face_value, precision: 19, scale: 4
      t.decimal :coupon_rate, precision: 5, scale: 2
      t.date :maturity_date
      t.string :isin
      t.string :rating
      t.string :interest_frequency, default: "quarterly"
    end
  end
end
