class GeneralizeBondSubtypesAndProducts < ActiveRecord::Migration[7.2]
  def up
    add_column :bond_lots, :product_code, :string
    add_index :bond_lots, :product_code

    execute <<~SQL
      UPDATE bond_lots
      SET product_code = CASE
        WHEN subtype = 'eod' THEN 'pl_eod'
        WHEN subtype = 'rod' THEN 'pl_rod'
        ELSE NULL
      END
    SQL

    execute <<~SQL
      UPDATE bond_lots
      SET subtype = CASE
        WHEN subtype IN ('eod', 'rod') THEN 'inflation_linked'
        WHEN subtype = 'other_bond' THEN 'other'
        ELSE subtype
      END
    SQL

    execute <<~SQL
      UPDATE bonds
      SET subtype = CASE
        WHEN subtype IN ('eod', 'rod') THEN 'inflation_linked'
        WHEN subtype = 'other_bond' THEN 'other'
        ELSE subtype
      END
    SQL

    change_column_default :bond_lots, :subtype, from: "other_bond", to: "other"

    remove_check_constraint :bond_lots, name: "check_bond_lots_non_inflation_rate_fields_present"
    add_check_constraint :bond_lots,
                         "(subtype::text = ANY (ARRAY['inflation_linked'::character varying, 'savings'::character varying]::text[])) OR rate_type IS NOT NULL AND coupon_frequency IS NOT NULL",
                         name: "check_bond_lots_non_inflation_rate_fields_present"
  end

  def down
    remove_check_constraint :bond_lots, name: "check_bond_lots_non_inflation_rate_fields_present"
    add_check_constraint :bond_lots,
                         "(subtype::text = ANY (ARRAY['eod'::character varying, 'rod'::character varying]::text[])) OR rate_type IS NOT NULL AND coupon_frequency IS NOT NULL",
                         name: "check_bond_lots_non_inflation_rate_fields_present"

    execute <<~SQL
      UPDATE bond_lots
      SET subtype = CASE
        WHEN subtype = 'inflation_linked' AND product_code = 'pl_eod' THEN 'eod'
        WHEN subtype = 'inflation_linked' AND product_code = 'pl_rod' THEN 'rod'
        WHEN subtype = 'other' THEN 'other_bond'
        ELSE subtype
      END
    SQL

    execute <<~SQL
      UPDATE bonds
      SET subtype = CASE
        WHEN subtype = 'inflation_linked' THEN 'eod'
        WHEN subtype = 'other' THEN 'other_bond'
        ELSE subtype
      END
    SQL

    change_column_default :bond_lots, :subtype, from: "other", to: "other_bond"

    remove_index :bond_lots, :product_code
    remove_column :bond_lots, :product_code
  end
end
