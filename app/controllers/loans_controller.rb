class LoansController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes(
    :id, :subtype, :rate_type, :interest_rate, :term_months, :initial_balance, :start_date,
    :down_payment, :insurance_rate, :insurance_rate_type, :day_count_convention,
    :principal_only_transfers, :rate_schedule_snapshot, :contracted_payment,
    :balloon_payment,
    { rate_changes: [ :effective_date, :rate ] }
  )

  def create
    super
    warn_if_balloon_was_not_applied if performed? && response.redirect?
  end

  def update
    attributes = account_params[:accountable_attributes]
    if attributes&.key?(:rate_changes) && attributes[:rate_schedule_snapshot].blank?
      @error_message = t("loans.edit.stale_rate_schedule")
      render :edit, status: :unprocessable_entity
    else
      super
      warn_if_balloon_was_not_applied if @account_updated
    end
  end

  private
    def warn_if_balloon_was_not_applied
      final_payment = @account.loan.amortization_schedule&.unapplied_balloon_final_payment
      return unless final_payment

      flash[:alert] = t("loans.balloon_not_applied", amount: final_payment.format)
    end

    def with_account_update_lock
      @account.accountable.with_schedule_lock do
        # The account row is locked too, but the request loaded it before the lock.
        @account.reload
        yield
      end
    end
end
