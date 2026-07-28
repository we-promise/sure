class LoansController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes(
    :id, :subtype, :rate_type, :interest_rate, :term_months, :initial_balance, :auto_split_payments
  )

  # NOTE: AccountableResource already registers set_manageable_account for
  # :edit/:update. Re-declaring the same callback replaces its action filter, so
  # we must list those actions here too (not just :resplit_payments).
  before_action :set_manageable_account, only: [ :edit, :update, :resplit_payments ]

  # Retroactively re-splits loan payments that were linked before automatic
  # splitting was enabled, so historical interest/principal is corrected.
  def resplit_payments
    Loan::PaymentResplitter.new(@account).call
    redirect_back_or_to @account, notice: t(".success")
  end
end
