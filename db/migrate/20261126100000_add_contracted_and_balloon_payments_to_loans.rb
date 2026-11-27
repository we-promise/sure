# frozen_string_literal: true

# The two figures a lender's own table can carry that the schedule used to
# only compute: the instalment actually charged (`contracted_payment`) and
# the total of the final instalment when the loan ends on a lump sum
# (`balloon_payment`). Both are fixed-rate concepts; the model rejects them
# on a variable loan.
#
# Nullable, positive when set -- a zero or negative figure is not a payment,
# it is no figure at all, and the check constraint says so where a crafted
# write cannot skip it.
class AddContractedAndBalloonPaymentsToLoans < ActiveRecord::Migration[8.1]
  def change
    add_column :loans, :contracted_payment, :decimal, precision: 19, scale: 4
    add_column :loans, :balloon_payment, :decimal, precision: 19, scale: 4

    add_check_constraint :loans,
      "contracted_payment IS NULL OR contracted_payment > 0",
      name: "chk_loans_contracted_payment_positive"
    add_check_constraint :loans,
      "balloon_payment IS NULL OR balloon_payment > 0",
      name: "chk_loans_balloon_payment_positive"
  end
end
