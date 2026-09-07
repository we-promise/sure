class LoansController < ApplicationController
  include AccountableResource

  before_action :set_offset_accounts, only: %i[new edit update]

  # `variable_rate_schedule` is deliberately absent: it is a jsonb column the
  # calculation reads, and permitting it would allow arbitrary JSON to be
  # written straight into it. The form submits `rate_changes` as structured
  # {effective_date, rate} rows and `Loan` assembles the column from them
  # (#14, risk R13).
  permitted_accountable_attributes(
    :id, :subtype, :rate_type, :interest_rate, :term_months, :initial_balance,
    :day_count_convention, :start_date,
    { offset_account_ids: [] },
    { rate_changes: [ :effective_date, :rate, :_destroy ] }
  )

  private

    def set_offset_accounts
      loan = @account&.accountable || Loan.new
      loan.offset_account_ids ||= loan.loan_offset_accounts.pluck(:account_id) if loan.persisted?
      @offset_accounts = LoanOffsetAccount.eligible_accounts_for(loan, viewer: Current.user)
    end
end
