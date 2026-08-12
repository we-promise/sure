class RecurringTransactionsController < ApplicationController
  layout "settings"

  def index
    @recurring_transactions = Current.family.recurring_transactions
                                    .accessible_by(Current.user)
                                    .includes(:merchant)
                                    .order(status: :asc, next_expected_date: :asc)
    @family = Current.family
  end

  def update_settings
    unless Current.family.update_recurring_settings(recurring_settings_params)
      @family = Current.family
      @recurring_transactions = Current.family.recurring_transactions
                                      .accessible_by(Current.user)
                                      .includes(:merchant)
                                      .order(status: :asc, next_expected_date: :asc)
      flash.now[:alert] = Current.family.errors.full_messages.to_sentence
      render :index, status: :unprocessable_entity
      return
    end

    respond_to do |format|
      format.html do
        flash[:notice] = t("recurring_transactions.settings_updated")
        redirect_to recurring_transactions_path
      end
    end
  end

  def identify
    count = RecurringTransaction.identify_patterns_for!(Current.family)

    respond_to do |format|
      format.html do
        flash[:notice] = t("recurring_transactions.identified", count: count)
        redirect_to recurring_transactions_path
      end
    end
  end

  def cleanup
    count = RecurringTransaction.cleanup_stale_for(Current.family)

    respond_to do |format|
      format.html do
        flash[:notice] = t("recurring_transactions.cleaned_up", count: count)
        redirect_to recurring_transactions_path
      end
    end
  end

  def toggle_status
    @recurring_transaction = Current.family.recurring_transactions.accessible_by(Current.user).find(params[:id])

    if @recurring_transaction.active?
      @recurring_transaction.mark_inactive!
      message = t("recurring_transactions.marked_inactive")
    else
      @recurring_transaction.mark_active!
      message = t("recurring_transactions.marked_active")
    end

    respond_to do |format|
      format.html do
        flash[:notice] = message
        redirect_to recurring_transactions_path
      end
    end
  end

  def destroy
    @recurring_transaction = Current.family.recurring_transactions.accessible_by(Current.user).find(params[:id])
    @recurring_transaction.destroy!

    flash[:notice] = t("recurring_transactions.deleted")
    redirect_to recurring_transactions_path
  end

  private

    def recurring_settings_params
      params.permit(
        :recurring_transactions_disabled,
        :recurring_detection_lookback_months,
        :recurring_detection_min_occurrences,
        :recurring_detection_recent_window_days,
        :recurring_detection_day_tolerance,
        :recurring_detection_day_cluster_stddev,
        :recurring_detection_amount_tolerance_percent
      )
    end
end
