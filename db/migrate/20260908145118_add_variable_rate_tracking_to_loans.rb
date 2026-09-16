class AddVariableRateTrackingToLoans < ActiveRecord::Migration[8.1]
  def change
    # Effective date => annual percentage, e.g. {"2026-04-01" => "6.15"}.
    # A JSONB column rather than a table: a handful of rows per loan, always
    # read together when a schedule is built, never queried across loans.
    add_column :loans, :variable_rate_schedule, :jsonb, null: false, default: {}

    # When the loan was drawn down. Optional -- origination otherwise comes
    # from the account's first valuation, which is where it came from before
    # this column existed and remains the answer for most loans.
    add_column :loans, :start_date, :date
  end
end
