class CreateLoanExtraRepayments < ActiveRecord::Migration[7.2]
  def change
    create_table :loan_extra_repayments, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :loan_scenario, null: false, type: :uuid, foreign_key: { on_delete: :cascade }

      t.string :kind, null: false
      t.decimal :amount, precision: 19, scale: 4, null: false

      t.date :occurs_on          # one_off only
      t.string :frequency        # recurring only
      t.integer :interval, default: 1
      t.date :starts_on
      t.date :ends_on

      t.timestamps
    end

    add_check_constraint :loan_extra_repayments, "amount > 0",
      name: "chk_loan_extra_repayments_amount_positive"

    # The two kinds carry disjoint columns, and the database says so rather
    # than trusting every writer to. A one_off with a frequency, or a recurring
    # with a fixed date, is not a partially-filled row -- it is two different
    # intents in one record, and the plan cannot resolve it.
    add_check_constraint :loan_extra_repayments,
      "(kind = 'one_off'   AND occurs_on IS NOT NULL AND frequency IS NULL) OR " \
      "(kind = 'recurring' AND frequency IS NOT NULL AND occurs_on IS NULL)",
      name: "chk_loan_extra_repayments_kind_coherent"

    add_check_constraint :loan_extra_repayments,
      "frequency IS NULL OR frequency IN ('weekly','fortnightly','monthly','quarterly','yearly')",
      name: "chk_loan_extra_repayments_frequency"

    # A non-positive interval reaches RecurringTransaction::Schedule and either
    # fails date generation (zero) or steps backwards forever (negative). The
    # model validates it; this is what holds when a write bypasses the model.
    add_check_constraint :loan_extra_repayments,
      "interval IS NULL OR interval > 0",
      name: "chk_loan_extra_repayments_interval_positive"

    # Reversed bounds are not an error the plan can report -- it silently
    # produces no occurrences, so the repayment looks saved and does nothing.
    add_check_constraint :loan_extra_repayments,
      "starts_on IS NULL OR ends_on IS NULL OR ends_on >= starts_on",
      name: "chk_loan_extra_repayments_date_order"

    # A recurring repayment has no stable anchor without a start date, and the
    # plan cannot invent one: see Loan::RepaymentPlan#recurring_dates.
    add_check_constraint :loan_extra_repayments,
      "kind <> 'recurring' OR starts_on IS NOT NULL",
      name: "chk_loan_extra_repayments_recurring_has_start"
  end
end
