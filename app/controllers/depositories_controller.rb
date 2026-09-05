class DepositoriesController <  ApplicationController
  include AccountableResource

  # Until now this controller declared none, so `accountable_attributes`
  # accepted only :id and a depository could carry no financial terms at all.
  # :subtype is deliberately absent: the depository form selects it on the
  # account builder, not inside fields_for :accountable.
  permitted_accountable_attributes(
    :id,
    :overdraft_limit,
    :overdraft_interest_rate,
    :intervention_fee_amount,
    :intervention_fee_threshold,
    :intervention_fee_monthly_cap,
    :intervention_fee_monthly_count_cap
  )
end
