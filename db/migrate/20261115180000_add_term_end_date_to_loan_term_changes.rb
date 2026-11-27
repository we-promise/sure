class AddTermEndDateToLoanTermChanges < ActiveRecord::Migration[8.1]
  def change
    # The day the terms that start on the effective date stop being fixed: the
    # end of a fixed-rate period, or the next renewal.
    add_column :loan_term_changes, :term_end_date, :date

    # A row can now record an end date alone, so the amounts are optional.
    remove_check_constraint :loan_term_changes,
      "extra_repayment IS NOT NULL OR balance IS NOT NULL OR payment IS NOT NULL",
      name: "chk_loan_term_changes_has_amount"
    # Rolling back restores the constraint above, which a row with only an
    # end date cannot meet. Such a row records nothing else, so it goes.
    reversible do |direction|
      direction.down do
        execute <<~SQL
          DELETE FROM loan_term_changes
          WHERE extra_repayment IS NULL AND balance IS NULL AND payment IS NULL
        SQL
      end
    end
    add_check_constraint :loan_term_changes,
      "extra_repayment IS NOT NULL OR balance IS NOT NULL OR payment IS NOT NULL OR term_end_date IS NOT NULL",
      name: "chk_loan_term_changes_records_something"
    add_check_constraint :loan_term_changes,
      "term_end_date IS NULL OR term_end_date > effective_date",
      name: "chk_loan_term_changes_term_ends_after_start"
  end
end
