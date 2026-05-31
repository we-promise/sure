class LoansController < ApplicationController
  include AccountableResource

  before_action :set_manageable_account, only: %i[edit update reconcile]

  permitted_accountable_attributes(
    :id,
    :subtype,
    :rate_type,
    :interest_rate,
    :term_months,
    :initial_balance,
    :annuity_enabled,
    :started_on,
    :payment_cadence,
    loan_rate_periods_attributes: [ :id, :starts_on, :annual_rate, :payment_amount, :_destroy ]
  )

  def reconcile
    result = @account.create_reconciliation(
      balance: @account.loan.amortization_schedule.scheduled_balance,
      date: Date.current
    )

    if result.success?
      redirect_back_or_to account_path(@account), notice: t(".success")
    else
      redirect_back_or_to account_path(@account), alert: result.error_message
    end
  end
end
