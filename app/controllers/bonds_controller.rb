class BondsController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes(
    :id,
    :initial_balance,
    :tax_wrapper,
    :auto_buy_new_issues
  )
end
