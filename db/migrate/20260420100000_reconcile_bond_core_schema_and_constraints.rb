class ReconcileBondCoreSchemaAndConstraints < ActiveRecord::Migration[7.2]
  def up
    ensure_enable_banking_psu_type_column
    drop_legacy_inflation_tables
    add_bonds_check_constraints
    add_bond_lots_financial_constraints
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "This migration drops legacy inflation tables and cannot be automatically reversed"
  end

  private

    def ensure_enable_banking_psu_type_column
      return unless table_exists?(:enable_banking_items)
      return if column_exists?(:enable_banking_items, :psu_type)

      add_column :enable_banking_items, :psu_type, :string
    end

    def drop_legacy_inflation_tables
      drop_table :gus_inflation_rates, if_exists: true
      drop_table :inflation_rates, if_exists: true
    end

    def add_bonds_check_constraints
      return unless table_exists?(:bonds)

      unless check_constraint_exists?(:bonds, name: "check_bonds_tax_wrapper_valid")
        add_check_constraint :bonds,
                             "tax_wrapper IN ('none','ike','ikze')",
                             name: "check_bonds_tax_wrapper_valid"
      end

      unless check_constraint_exists?(:bonds, name: "check_bonds_subtype_valid")
        add_check_constraint :bonds,
                             "subtype IS NULL OR subtype IN ('zero_coupon','fixed_coupon','inflation_linked','savings','other')",
                             name: "check_bonds_subtype_valid"
      end

      unless check_constraint_exists?(:bonds, name: "check_bonds_rate_type_valid")
        add_check_constraint :bonds,
                             "rate_type IS NULL OR rate_type IN ('fixed','variable')",
                             name: "check_bonds_rate_type_valid"
      end

      unless check_constraint_exists?(:bonds, name: "check_bonds_coupon_frequency_valid")
        add_check_constraint :bonds,
                             "coupon_frequency IS NULL OR coupon_frequency IN ('monthly','quarterly','semi_annual','annual','at_maturity')",
                             name: "check_bonds_coupon_frequency_valid"
      end
    end

    def add_bond_lots_financial_constraints
      return unless table_exists?(:bond_lots)

      unless check_constraint_exists?(:bond_lots, name: "check_bond_lots_tax_rate_range")
        add_check_constraint :bond_lots,
                             "tax_rate >= 0 AND tax_rate <= 100",
                             name: "check_bond_lots_tax_rate_range"
      end

      unless check_constraint_exists?(:bond_lots, name: "check_bond_lots_non_negative_early_redemption_fee")
        add_check_constraint :bond_lots,
                             "early_redemption_fee IS NULL OR early_redemption_fee >= 0",
                             name: "check_bond_lots_non_negative_early_redemption_fee"
      end

      unless check_constraint_exists?(:bond_lots, name: "check_bond_lots_non_negative_settlement_amount")
        add_check_constraint :bond_lots,
                             "settlement_amount IS NULL OR settlement_amount >= 0",
                             name: "check_bond_lots_non_negative_settlement_amount"
      end

      unless check_constraint_exists?(:bond_lots, name: "check_bond_lots_non_negative_tax_withheld")
        add_check_constraint :bond_lots,
                             "tax_withheld IS NULL OR tax_withheld >= 0",
                             name: "check_bond_lots_non_negative_tax_withheld"
      end

      unless check_constraint_exists?(:bond_lots, name: "check_bond_lots_positive_units")
        add_check_constraint :bond_lots,
                             "units IS NULL OR units > 0",
                             name: "check_bond_lots_positive_units"
      end

      unless check_constraint_exists?(:bond_lots, name: "check_bond_lots_positive_nominal_per_unit")
        add_check_constraint :bond_lots,
                             "nominal_per_unit IS NULL OR nominal_per_unit > 0",
                             name: "check_bond_lots_positive_nominal_per_unit"
      end
    end
end
