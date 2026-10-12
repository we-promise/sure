class AddPlannerToRetirementPlans < ActiveRecord::Migration[8.1]
  def up
    # A database can already have these columns and tables from an earlier
    # migration that recorded a different version, so this one is still
    # pending there. Every step below skips what exists, leaving the plans,
    # their streams and their accounts as they are.

    # The year-by-year planner. Every new column has a default or allows null,
    # so a plan saved with only the simple settings keeps saving.
    #
    # A year, not a date of birth: the engine works in whole years, and a
    # year is all an age to plan to needs.
    add_column :retirement_plans, :birth_year, :integer, if_not_exists: true
    add_column :retirement_plans, :end_age, :integer, null: false, default: 90, if_not_exists: true
    add_column :retirement_plans, :inflation_rate, :decimal, precision: 6, scale: 4, null: false, default: "0.03",
      if_not_exists: true
    # traditional: retire on the plan's date. fire: solve for the earliest
    # year the money lasts to the end age.
    add_column :retirement_plans, :mode, :string, null: false, default: "traditional", if_not_exists: true
    # When the plan's streams were first seeded from the user's spending and
    # loans. Seeding happens once: a user who deletes a seeded stream has
    # decided it does not belong, and must not see it come back.
    add_column :retirement_plans, :streams_seeded_on, :date, if_not_exists: true

    add_check_constraint_unless_named :retirement_plans,
      "birth_year IS NULL OR (birth_year >= 1900 AND birth_year <= 2100)",
      name: "chk_retirement_plans_birth_year"
    add_check_constraint_unless_named :retirement_plans, "end_age >= 50 AND end_age <= 120",
      name: "chk_retirement_plans_end_age"
    add_check_constraint_unless_named :retirement_plans, "inflation_rate > -1 AND inflation_rate <= 1",
      name: "chk_retirement_plans_inflation_rate"
    add_check_constraint_unless_named :retirement_plans, "mode IN ('traditional', 'fire')",
      name: "chk_retirement_plans_mode"

    # What the plan spends and receives, year by year.
    create_table :retirement_plan_streams, id: :uuid, if_not_exists: true do |t|
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

    add_check_constraint_unless_named :retirement_plan_streams, "kind IN ('expense', 'income', 'one_off')",
      name: "chk_retirement_plan_streams_kind"
    add_check_constraint_unless_named :retirement_plan_streams, "annual_amount > 0",
      name: "chk_retirement_plan_streams_amount"
    add_check_constraint_unless_named :retirement_plan_streams,
      "source IN ('seeded_living_costs', 'seeded_loan', 'manual')",
      name: "chk_retirement_plan_streams_source"
    add_check_constraint_unless_named :retirement_plan_streams,
      "end_year IS NULL OR start_year IS NULL OR end_year >= start_year",
      name: "chk_retirement_plan_streams_years"

    # The accounts that fund the plan, when the user picks them. None linked
    # means the default set: the cash, investment and crypto accounts the
    # user counts in their finances.
    create_table :retirement_plan_accounts, id: :uuid, if_not_exists: true do |t|
      t.references :retirement_plan, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :account, null: false, type: :uuid, foreign_key: { on_delete: :cascade }

      t.timestamps
    end

    unless index_exists?(:retirement_plan_accounts, [ :retirement_plan_id, :account_id ],
                         name: "idx_retirement_plan_accounts_unique")
      add_index :retirement_plan_accounts, [ :retirement_plan_id, :account_id ], unique: true,
        name: "idx_retirement_plan_accounts_unique"
    end
  end

  def down
    drop_table :retirement_plan_accounts
    drop_table :retirement_plan_streams

    %w[birth_year end_age inflation_rate mode].each do |column|
      remove_check_constraint :retirement_plans, name: "chk_retirement_plans_#{column}"
    end
    remove_columns :retirement_plans, :birth_year, :end_age, :inflation_rate, :mode, :streams_seeded_on
  end

  private
    # Skips on the name alone: a constraint already under that name is the one
    # a re-run must not add again, whatever options it was created with.
    def add_check_constraint_unless_named(table, expression, name:)
      return if check_constraint_exists?(table, name: name)

      add_check_constraint table, expression, name: name
    end
end
