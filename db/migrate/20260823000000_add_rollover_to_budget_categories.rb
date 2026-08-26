class AddRolloverToBudgetCategories < ActiveRecord::Migration[7.2]
  def change
    add_column :budget_categories, :rollover_enabled, :boolean, null: false, default: false
    add_column :budget_categories, :rolled_over_amount, :decimal, precision: 19, scale: 4, null: false, default: 0

    # The calculator floors the carry at zero, but it writes through
    # `upsert_all` and nothing else stops a direct write. A negative carry
    # would quietly SUBTRACT from `available_to_spend` — an envelope that
    # shrinks for no visible reason. Enforced in the database because that is
    # the one door every writer goes through.
    add_check_constraint :budget_categories, "rolled_over_amount >= 0",
                         name: "chk_budget_categories_rolled_over_amount_non_negative"
  end
end
