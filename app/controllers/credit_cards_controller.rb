class CreditCardsController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes(
    :id,
    :subtype,
    :available_credit,
    :minimum_payment,
    :apr,
    :annual_fee,
    :expiration_date
  )
end
