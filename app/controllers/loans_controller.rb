class LoansController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes(
    :id, :subtype, :rate_type, :interest_rate, :term_months, :initial_balance,
    :origination_date, :maturity_date, :apr, :insurance_monthly_amount,
    :scheduled_payment, :early_repayment_terms
  )
end
