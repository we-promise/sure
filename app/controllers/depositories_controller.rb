class DepositoriesController <  ApplicationController
  include AccountableResource

  permitted_accountable_attributes :subtype
end
