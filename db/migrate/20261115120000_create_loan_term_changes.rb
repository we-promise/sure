class CreateLoanTermChanges < ActiveRecord::Migration[8.1]
  def change
    create_table :loan_term_changes, id: :uuid do |t|
      t.references :loan, null: false, type: :uuid, index: false, foreign_key: { on_delete: :cascade }
      t.date :effective_date, null: false
      # What the borrower repaid on top of the instalment.
      t.decimal :extra_repayment, precision: 19, scale: 4
      # The balance the lender confirmed for the effective date.
      t.decimal :balance, precision: 19, scale: 4
      # The instalment the lender set. Blank means re-amortised over the
      # remaining term.
      t.decimal :payment, precision: 19, scale: 4
      t.timestamps
    end

    add_index :loan_term_changes, %i[loan_id effective_date], unique: true
    add_check_constraint :loan_term_changes,
      "extra_repayment IS NOT NULL OR balance IS NOT NULL OR payment IS NOT NULL",
      name: "chk_loan_term_changes_has_amount"
    add_check_constraint :loan_term_changes,
      "extra_repayment IS NULL OR balance IS NULL",
      name: "chk_loan_term_changes_one_balance_change"
    add_check_constraint :loan_term_changes,
      "extra_repayment IS NULL OR extra_repayment > 0",
      name: "chk_loan_term_changes_extra_repayment_positive"
    add_check_constraint :loan_term_changes,
      "balance IS NULL OR balance >= 0",
      name: "chk_loan_term_changes_balance_non_negative"
    add_check_constraint :loan_term_changes,
      "payment IS NULL OR payment >= 0",
      name: "chk_loan_term_changes_payment_non_negative"
  end
end
