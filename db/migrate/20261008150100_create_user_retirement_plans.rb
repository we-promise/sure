class CreateUserRetirementPlans < ActiveRecord::Migration[8.1]
  def change
    # One plan per user, not per family. The figures a plan drives are built
    # from the accounts its user can see, so a shared plan would project a
    # different set of accounts for every member who opened it.
    create_table :retirement_plans, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :user, null: false, type: :uuid, index: { unique: true }, foreign_key: { on_delete: :cascade }

      t.decimal :safe_withdrawal_rate, precision: 5, scale: 4, null: false, default: "0.04"
      t.decimal :expected_annual_return, precision: 6, scale: 4, null: false, default: "0.05"
      # NULL means "derive it from income and expenses", which is a different
      # answer from an explicit zero.
      t.decimal :savings_rate, precision: 5, scale: 4
      t.date :retirement_date

      t.timestamps
    end

    # A zero rate divides the FI number by zero; above one withdraws more than
    # the whole portfolio each year.
    add_check_constraint :retirement_plans,
      "safe_withdrawal_rate > 0 AND safe_withdrawal_rate <= 1",
      name: "chk_retirement_plans_safe_withdrawal_rate"

    # A return of -100% or worse leaves nothing to compound.
    add_check_constraint :retirement_plans,
      "expected_annual_return > -1 AND expected_annual_return <= 1",
      name: "chk_retirement_plans_expected_annual_return"

    add_check_constraint :retirement_plans,
      "savings_rate IS NULL OR (savings_rate >= 0 AND savings_rate <= 1)",
      name: "chk_retirement_plans_savings_rate"
  end
end
