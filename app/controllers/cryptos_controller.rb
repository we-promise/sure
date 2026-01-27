class CryptosController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes :id, :tax_treatment
end
