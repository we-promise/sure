class DepositoriesController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes(
    :id,
    :interest_rate,
    :interest_enabled
  )
end
