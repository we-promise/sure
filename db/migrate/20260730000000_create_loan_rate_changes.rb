class CreateLoanRateChanges < ActiveRecord::Migration[7.2]
  def change
    create_table :loan_rate_changes, id: :uuid do |t|
      t.references :loan, null: false, foreign_key: true, type: :uuid, index: false
      t.date :effective_date, null: false
      t.decimal :rate, precision: 10, scale: 3, null: false

      t.timestamps
    end

    # One rate per loan per effective date; the accrual engine resolves the rate
    # in effect on a given day as the latest change on or before it, so a second
    # row on the same date would be ambiguous.
    add_index :loan_rate_changes, [ :loan_id, :effective_date ],
      unique: true, name: "index_loan_rate_changes_on_loan_id_and_effective_date"

    add_check_constraint :loan_rate_changes, "rate >= 0",
      name: "loan_rate_changes_rate_non_negative"
  end
end
