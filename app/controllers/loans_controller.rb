class LoansController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes(
    :id, :subtype, :rate_type, :interest_rate, :term_months, :initial_balance, :start_date,
    :day_count_convention,
    { rate_changes: [ :effective_date, :rate ] }
  )
end
