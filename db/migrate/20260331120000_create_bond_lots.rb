class CreateBondLots < ActiveRecord::Migration[7.2]
  def change
    create_table :bond_lots, id: :uuid do |t|
      t.references :bond, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.date :purchased_on, null: false
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.integer :term_months, null: false
      t.date :maturity_date, null: false
      t.decimal :interest_rate, precision: 10, scale: 3
      t.string :subtype, null: false, default: "other"
      t.string :rate_type
      t.string :coupon_frequency
      t.references :entry, type: :uuid, foreign_key: { to_table: :entries, on_delete: :nullify }, index: false

      t.date :issue_date
      t.decimal :first_period_rate, precision: 10, scale: 3
      t.decimal :inflation_margin, precision: 10, scale: 3
      t.decimal :inflation_rate_assumption, precision: 10, scale: 3
      t.integer :cpi_lag_months
      t.decimal :early_redemption_fee, precision: 19, scale: 4
      t.decimal :units, precision: 12, scale: 2
      t.decimal :nominal_per_unit, precision: 19, scale: 4
      t.boolean :auto_fetch_inflation, null: false, default: true

      t.boolean :auto_close_on_maturity, null: false, default: true
      t.date :closed_on
      t.decimal :settlement_amount, precision: 19, scale: 4
      t.decimal :tax_withheld, precision: 19, scale: 4
      t.string :tax_strategy, null: false, default: "standard"
      t.decimal :tax_rate, precision: 6, scale: 3, null: false, default: 19.0
      t.boolean :requires_rate_review, null: false, default: false

      t.string :product_code
      t.string :inflation_provider

      t.timestamps
    end

    add_index :bond_lots, [ :bond_id, :purchased_on ]
    add_index :bond_lots, :subtype
    add_index :bond_lots, :issue_date
    add_index :bond_lots, :closed_on
    add_index :bond_lots, [ :bond_id, :closed_on ]
    add_index :bond_lots, :requires_rate_review
    add_index :bond_lots, :product_code
    add_index :bond_lots, :inflation_provider
    add_index :bond_lots,
              %i[auto_close_on_maturity maturity_date closed_on],
              name: "index_bond_lots_on_settlement_eligibility"
    add_index :bond_lots, :entry_id, unique: true, where: "entry_id IS NOT NULL"

    # Database-level constraints for domain invariants
    add_check_constraint :bond_lots, "amount > 0", name: "check_bond_lots_positive_amount"
    add_check_constraint :bond_lots, "term_months > 0", name: "check_bond_lots_positive_term"
    add_check_constraint :bond_lots, "maturity_date >= purchased_on", name: "check_bond_lots_maturity_after_purchase"
    add_check_constraint :bond_lots, "subtype IS NOT NULL", name: "check_bond_lots_subtype_not_null"
    add_check_constraint :bond_lots,
                         "(subtype IN ('inflation_linked')) OR (rate_type IS NOT NULL AND coupon_frequency IS NOT NULL)",
                         name: "check_bond_lots_non_inflation_rate_fields_present"
  end
end
