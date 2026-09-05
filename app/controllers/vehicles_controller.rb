class VehiclesController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes(:id, *Vehicle::IMPORTABLE_ATTRIBUTES)
end
