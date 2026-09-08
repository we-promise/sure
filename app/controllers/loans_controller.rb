class LoansController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes(
    :id, :subtype, :rate_type, :interest_rate, :term_months, :initial_balance,
    :accrue_interest, :interest_accrual_day, :interest_accrual_start_date,
    rate_changes_attributes: [ :id, :effective_date, :rate, :_destroy ]
  )
end
