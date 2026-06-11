class InvestmentsController < ApplicationController
  include AccountableResource

  require_module! :investments

  permitted_accountable_attributes :id, :subtype
end
