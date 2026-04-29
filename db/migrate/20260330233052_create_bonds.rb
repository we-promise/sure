class CreateBonds < ActiveRecord::Migration[7.2]
  def change
    create_table :bonds, id: :uuid do |t|
      t.decimal :initial_balance, precision: 19, scale: 4
      t.decimal :interest_rate, precision: 10, scale: 3
      t.integer :term_months
      t.string :rate_type
      t.date :maturity_date
      t.string :coupon_frequency
      t.string :subtype
      t.jsonb :locked_attributes, default: {}, null: false
      t.string :tax_wrapper, default: "none", null: false
      t.boolean :auto_buy_new_issues, default: false, null: false
      t.timestamps
    end

    add_index :bonds, :tax_wrapper
  end
end
