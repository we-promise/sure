class AddPlannerToRetirementPlans < ActiveRecord::Migration[8.1]
  def change
    # The year-by-year planner. Every new column has a default or allows null,
    # so a plan saved with only the simple settings keeps saving.
    change_table :retirement_plans, bulk: true do |t|
      # A year, not a date of birth: the engine works in whole years, and a
      # year is all an age to plan to needs.
      t.integer :birth_year
      t.integer :end_age, null: false, default: 90
      t.decimal :inflation_rate, precision: 6, scale: 4, null: false, default: "0.03"
      # traditional: retire on the plan's date. fire: solve for the earliest
      # year the money lasts to the end age.
      t.string :mode, null: false, default: "traditional"
      # When the plan's streams were first seeded from the user's spending and
      # loans. Seeding happens once: a user who deletes a seeded stream has
      # decided it does not belong, and must not see it come back.
      t.date :streams_seeded_on
    end

    add_check_constraint :retirement_plans, "birth_year IS NULL OR (birth_year >= 1900 AND birth_year <= 2100)",
      name: "chk_retirement_plans_birth_year"
    add_check_constraint :retirement_plans, "end_age >= 50 AND end_age <= 120",
      name: "chk_retirement_plans_end_age"
    add_check_constraint :retirement_plans, "inflation_rate > -1 AND inflation_rate <= 1",
      name: "chk_retirement_plans_inflation_rate"
    add_check_constraint :retirement_plans, "mode IN ('traditional', 'fire')",
      name: "chk_retirement_plans_mode"

    # What the plan spends and receives, year by year.
    create_table :retirement_plan_streams, id: :uuid do |t|
      t.references :retirement_plan, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      # expense: recurring spending, drawn from the portfolio once retired.
      # income: a pension or similar, set against that spending.
      # one_off: a single amount out of the portfolio in its start year.
      t.string :kind, null: false
      t.string :name, null: false
      t.decimal :annual_amount, precision: 19, scale: 4, null: false
      # Calendar years, inclusive. A blank start runs from today; a blank end
      # runs to the plan's end age.
      t.integer :start_year
      t.integer :end_year
      # Grows with the plan's inflation rate from today when true.
      t.boolean :indexed, null: false, default: true
      t.string :source, null: false, default: "manual"
      # The loan a seeded repayment stream came from. Nullified, not
      # cascaded, when the account goes: the user may have edited the stream.
      t.references :account, type: :uuid, foreign_key: { on_delete: :nullify }

      t.timestamps
    end

    add_check_constraint :retirement_plan_streams, "kind IN ('expense', 'income', 'one_off')",
      name: "chk_retirement_plan_streams_kind"
    add_check_constraint :retirement_plan_streams, "annual_amount > 0",
      name: "chk_retirement_plan_streams_amount"
    add_check_constraint :retirement_plan_streams, "source IN ('seeded_living_costs', 'seeded_loan', 'manual')",
      name: "chk_retirement_plan_streams_source"
    add_check_constraint :retirement_plan_streams, "end_year IS NULL OR start_year IS NULL OR end_year >= start_year",
      name: "chk_retirement_plan_streams_years"

    # The accounts that fund the plan, when the user picks them. None linked
    # means the default set: the cash, investment and crypto accounts the
    # user counts in their finances.
    create_table :retirement_plan_accounts, id: :uuid do |t|
      t.references :retirement_plan, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :account, null: false, type: :uuid, foreign_key: { on_delete: :cascade }

      t.timestamps
    end

    add_index :retirement_plan_accounts, [ :retirement_plan_id, :account_id ], unique: true, name: "idx_retirement_plan_accounts_unique"
  end
end
