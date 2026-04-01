class ReconfigureBondProductsForEodRod < ActiveRecord::Migration[7.2]
  def up
    add_column :bond_lots, :issue_date, :date
    add_column :bond_lots, :first_period_rate, :decimal, precision: 10, scale: 3
    add_column :bond_lots, :inflation_margin, :decimal, precision: 10, scale: 3
    add_column :bond_lots, :inflation_rate_assumption, :decimal, precision: 10, scale: 3
    add_column :bond_lots, :cpi_lag_months, :integer
    add_column :bond_lots, :early_redemption_fee, :decimal, precision: 19, scale: 4
    add_column :bond_lots, :units, :decimal, precision: 12, scale: 2
    add_column :bond_lots, :nominal_per_unit, :decimal, precision: 19, scale: 4

    add_index :bond_lots, :issue_date

    execute <<~SQL
      UPDATE bonds
      SET subtype = CASE
        WHEN subtype IN ('eod', 'rod', 'other_bond') THEN subtype
        ELSE 'other_bond'
      END
    SQL

    execute <<~SQL
      UPDATE bond_lots
      SET subtype = CASE
        WHEN subtype IN ('eod', 'rod', 'other_bond') THEN subtype
        ELSE 'other_bond'
      END
    SQL

    execute <<~SQL
      UPDATE bonds
      SET term_months = 120,
          rate_type = COALESCE(rate_type, 'variable'),
          coupon_frequency = COALESCE(coupon_frequency, 'at_maturity')
      WHERE subtype = 'eod' AND term_months IS NULL
    SQL

    execute <<~SQL
      UPDATE bonds
      SET term_months = 144,
          rate_type = COALESCE(rate_type, 'variable'),
          coupon_frequency = COALESCE(coupon_frequency, 'at_maturity')
      WHERE subtype = 'rod' AND term_months IS NULL
    SQL

    execute <<~SQL
      UPDATE bond_lots
      SET term_months = 120,
          rate_type = COALESCE(rate_type, 'variable'),
          coupon_frequency = COALESCE(coupon_frequency, 'at_maturity')
      WHERE subtype = 'eod' AND term_months IS NULL
    SQL

    execute <<~SQL
      UPDATE bond_lots
      SET term_months = 144,
          rate_type = COALESCE(rate_type, 'variable'),
          coupon_frequency = COALESCE(coupon_frequency, 'at_maturity')
      WHERE subtype = 'rod' AND term_months IS NULL
    SQL
  end

  def down
    remove_index :bond_lots, :issue_date

    remove_column :bond_lots, :issue_date
    remove_column :bond_lots, :first_period_rate
    remove_column :bond_lots, :inflation_margin
    remove_column :bond_lots, :inflation_rate_assumption
    remove_column :bond_lots, :cpi_lag_months
    remove_column :bond_lots, :early_redemption_fee
    remove_column :bond_lots, :units
    remove_column :bond_lots, :nominal_per_unit

    def down
      raise ActiveRecord::IrreversibleMigration,
            "Cannot safely reverse subtype normalization; original eod/rod/other_bond distinctions would be lost."
    end
  end
end
