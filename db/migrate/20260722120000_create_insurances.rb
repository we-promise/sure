class CreateInsurances < ActiveRecord::Migration[7.2]
  def change
    create_table :insurances, id: :uuid do |t|
      t.string :subtype
      t.string :policy_number
      t.decimal :coverage_amount, precision: 19, scale: 4
      t.decimal :premium_amount, precision: 19, scale: 4
      t.string :premium_frequency
      t.date :effective_date
      t.date :expiration_date
      t.date :renewal_date
      t.string :insured_name
      t.text :beneficiaries
      t.jsonb :locked_attributes, default: {}

      t.timestamps
    end
  end
end
