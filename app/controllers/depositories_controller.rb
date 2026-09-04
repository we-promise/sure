class DepositoriesController <  ApplicationController
  include AccountableResource

  permitted_accountable_attributes(
    :id, :subtype, :fixed_return_rate, :fixed_return_frequency, :fixed_return_start_date
  )
end
