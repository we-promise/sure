class AddAmortizationBoundsToLoans < ActiveRecord::Migration[7.2]
  def change
    # Without an upper bound, term_months is directly settable from the loan
    # edit form and drives an array allocation, a BigDecimal exponentiation,
    # and a bulk insert sized to the term on every rebuild -- an unbounded
    # value there is a resource-exhaustion path, not just a display glitch.
    add_check_constraint :loans,
                          "term_months IS NULL OR (term_months > 0 AND term_months <= 1200)",
                          name: "chk_loans_term_months_bounds"
    add_check_constraint :loans,
                          "interest_rate IS NULL OR (interest_rate >= 0 AND interest_rate <= 100)",
                          name: "chk_loans_interest_rate_bounds"

    # insert_all! bypasses AR validations entirely, so these are the only
    # backstop against a future calculation bug persisting nonsensical rows.
    add_check_constraint :loan_amortizations, "payment_number > 0",
                          name: "chk_loan_amortizations_payment_number_positive"
    add_check_constraint :loan_amortizations, "payment_amount >= 0",
                          name: "chk_loan_amortizations_payment_amount_non_negative"
    add_check_constraint :loan_amortizations, "principal_payment >= 0",
                          name: "chk_loan_amortizations_principal_payment_non_negative"
    add_check_constraint :loan_amortizations, "interest_payment >= 0",
                          name: "chk_loan_amortizations_interest_payment_non_negative"
    add_check_constraint :loan_amortizations, "beginning_balance >= 0",
                          name: "chk_loan_amortizations_beginning_balance_non_negative"
    add_check_constraint :loan_amortizations, "ending_balance >= 0",
                          name: "chk_loan_amortizations_ending_balance_non_negative"
    add_check_constraint :loan_amortizations,
                          "interest_rate >= 0 AND interest_rate <= 100",
                          name: "chk_loan_amortizations_interest_rate_bounds"
  end
end
