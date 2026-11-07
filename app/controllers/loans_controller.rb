class LoansController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes(
    :id, :subtype, :rate_type, :interest_rate, :term_months, :initial_balance, :start_date,
    :down_payment, :insurance_rate, :insurance_rate_type, :day_count_convention, :rate_schedule_snapshot,
    { rate_changes: [ :effective_date, :rate ] }
  )

  def update
    attributes = account_params[:accountable_attributes]
    if attributes&.key?(:rate_changes) && attributes[:rate_schedule_snapshot].blank?
      @error_message = t("loans.edit.stale_rate_schedule")
      render :edit, status: :unprocessable_entity
    else
      super
    end
  end

  private
    def with_account_update_lock
      @account.accountable.with_schedule_lock do
        # The account row is locked too, but the request loaded it before the lock.
        @account.reload
        yield
      end
    end
end
