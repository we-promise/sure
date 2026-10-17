# A borrower's loan insurance premium, which many lenders quote as part of the
# monthly instalment. Two shapes cover what lenders sell: a level-term premium
# charged on the original principal for the life of the loan, and a decreasing
# premium charged on what is still outstanding.
#
# The rate is annual and expressed in percent, like `interest_rate`, so 0.36
# means 0.36% a year. precision 8/scale 4 holds a rate to a hundredth of a
# basis point, which is finer than any lender quotes.
class AddInsuranceToLoans < ActiveRecord::Migration[8.1]
  def change
    add_column :loans, :insurance_rate, :decimal, precision: 8, scale: 4
    add_column :loans, :insurance_rate_type, :string

    add_check_constraint :loans,
      "insurance_rate IS NULL OR insurance_rate >= 0",
      name: "chk_loans_insurance_rate_non_negative"
    add_check_constraint :loans,
      "insurance_rate_type IS NULL OR insurance_rate_type IN ('level_term', 'decreasing_life')",
      name: "chk_loans_insurance_rate_type"
  end
end
