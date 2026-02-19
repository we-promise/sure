class CryptosController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes :id, :subtype, :tax_treatment
end
