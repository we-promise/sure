class DepositoriesController <  ApplicationController
  include AccountableResource

  permitted_accountable_attributes :id, :subtype
end
