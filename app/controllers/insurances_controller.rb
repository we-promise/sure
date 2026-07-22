class InsurancesController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes :id, *Insurance::POLICY_ATTRIBUTES
end
