class AddTermsToLoans < ActiveRecord::Migration[8.1]
  def change
    # `loans` already held interest_rate, rate_type and term_months, but nothing
    # anchored them in time, so neither an end date nor a remaining instalment
    # count could be derived. term_months without an origination date is a
    # duration with no origin.
    add_column :loans, :origination_date, :date
    add_column :loans, :maturity_date, :date

    # Distinct from interest_rate on purpose. interest_rate is the nominal rate
    # used by the amortization formula; this is the all-in figure a French
    # lender must disclose (TAEG), which includes fees and insurance and must
    # never be fed to that formula.
    add_column :loans, :apr, :decimal, precision: 10, scale: 3

    # Borrower's insurance premium, billed alongside the instalment and absent
    # from the amortization schedule. The true monthly cost is the instalment
    # plus this, and leaving it out understates the burden every month.
    add_column :loans, :insurance_monthly_amount, :decimal, precision: 19, scale: 4

    # Loan#monthly_payment can only compute an instalment for a fixed-rate loan
    # (it returns nil for every other rate_type). This is the escape hatch: the
    # amount actually debited, entered by hand, which takes precedence when set.
    add_column :loans, :scheduled_payment, :decimal, precision: 19, scale: 4

    # Free text on purpose. Early-repayment clauses are prose (notice periods,
    # capped indemnities, exempt cases) and modelling them would encode one
    # jurisdiction's rules into a column.
    add_column :loans, :early_repayment_terms, :text

    add_check_constraint :loans,
                         "scheduled_payment IS NULL OR scheduled_payment >= 0",
                         name: "chk_loans_scheduled_payment_non_negative"

    # Both stay nullable (an unknown TAEG or premium is a legitimate state),
    # but neither can be negative: a negative TAEG would be reported to the
    # user as a rate, and a negative premium would understate the monthly cost.
    add_check_constraint :loans,
                         "apr IS NULL OR apr >= 0",
                         name: "chk_loans_apr_non_negative"
    add_check_constraint :loans,
                         "insurance_monthly_amount IS NULL OR insurance_monthly_amount >= 0",
                         name: "chk_loans_insurance_non_negative"
    add_check_constraint :loans,
                         "origination_date IS NULL OR maturity_date IS NULL OR origination_date <= maturity_date",
                         name: "chk_loans_term_dates_order"
  end
end
