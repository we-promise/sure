class LoansController < ApplicationController
  include AccountableResource

  before_action :set_offset_accounts, only: %i[new edit update]

  permitted_accountable_attributes(
    :id, :subtype, :rate_type, :interest_rate, :term_months, :initial_balance,
    :day_count_convention,
    { offset_account_ids: [] }
  )

  private

    def set_offset_accounts
      loan = @account&.accountable || Loan.new
      loan.offset_account_ids ||= loan.loan_offset_accounts.pluck(:account_id) if loan.persisted?
      @offset_accounts = LoanOffsetAccount.eligible_accounts_for(loan, viewer: Current.user)
    end
end
