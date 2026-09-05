class CryptosController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes(:id, :subtype, *Crypto::IMPORTABLE_ATTRIBUTES)
end
