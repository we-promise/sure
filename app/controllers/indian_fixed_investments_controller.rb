class IndianFixedInvestmentsController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes :id, :subtype, :interest_rate, :maturity_date, :deposit_amount, :deposit_frequency
end
