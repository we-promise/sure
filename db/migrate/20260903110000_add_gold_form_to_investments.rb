class AddGoldFormToInvestments < ActiveRecord::Migration[7.2]
  def up
    add_column :investments, :gold_form, :string
    execute <<~SQL.squish
      UPDATE investments
      SET gold_form = CASE
        WHEN EXISTS (
          SELECT 1
          FROM accounts
          WHERE accounts.accountable_type = 'Investment'
            AND accounts.accountable_id = investments.id
            AND (
              EXISTS (SELECT 1 FROM holdings WHERE holdings.account_id = accounts.id)
              OR EXISTS (
                SELECT 1 FROM entries
                WHERE entries.account_id = accounts.id
                  AND entries.entryable_type = 'Trade'
              )
            )
        ) THEN 'digital'
        ELSE 'physical'
      END
      WHERE subtype = 'gold'
    SQL

    add_check_constraint :investments,
                         "gold_form IS NULL OR gold_form IN ('physical', 'digital')",
                         name: "investments_gold_form_valid",
                         validate: false
    add_check_constraint :investments,
                         "gold_form IS NULL OR subtype IS NOT DISTINCT FROM 'gold'",
                         name: "investments_gold_form_requires_gold_subtype",
                         validate: false
    add_check_constraint :investments,
                         "gold_form IS NOT DISTINCT FROM 'physical' OR (gold_weight IS NULL AND gold_weight_unit IS NULL AND gold_karat IS NULL AND gold_manual_value IS NULL)",
                         name: "investments_physical_gold_details_require_physical_form",
                         validate: false
  end

  def down
    remove_check_constraint :investments, name: "investments_physical_gold_details_require_physical_form"
    remove_check_constraint :investments, name: "investments_gold_form_requires_gold_subtype"
    remove_check_constraint :investments, name: "investments_gold_form_valid"
    remove_column :investments, :gold_form
  end
end
