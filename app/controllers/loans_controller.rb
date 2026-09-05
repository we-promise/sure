class LoansController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes(:id, :subtype, *Loan::IMPORTABLE_ATTRIBUTES)
end
