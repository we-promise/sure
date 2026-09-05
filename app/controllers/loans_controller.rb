class LoansController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes(
    :id, :subtype, :rate_type, :interest_rate, :insurance_rate_type, :insurance_rate, :term_months, :initial_balance, :down_payment, :start_date
  )
end
