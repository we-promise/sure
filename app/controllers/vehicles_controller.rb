class VehiclesController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes(
    :id, :make, :model, :year, :mileage_value, :mileage_unit,
    :initial_balance, :purchase_date
  )
end
