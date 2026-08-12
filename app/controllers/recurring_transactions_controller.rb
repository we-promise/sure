class RecurringTransactionsController < ApplicationController
  layout "settings"

  def index
    @recurring_transactions = Current.family.recurring_transactions
                                    .accessible_by(Current.user)
                                    .visible
                                    .includes(:merchant)
                                    .order(status: :asc, next_expected_date: :asc)
    @dismissed_recurring_transactions = Current.family.recurring_transactions
                                    .accessible_by(Current.user)
                                    .dismissed
                                    .includes(:merchant)
                                    .order(updated_at: :desc)
    @family = Current.family
  end

  def update_settings
    Current.family.update!(recurring_settings_params)

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
    @recurring_transaction = Current.family.recurring_transactions.accessible_by(Current.user).visible.find(params[:id])

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
    @recurring_transaction = Current.family.recurring_transactions.accessible_by(Current.user).visible.find(params[:id])
    @recurring_transaction.dismiss!

    flash[:notice] = t("recurring_transactions.deleted")
    redirect_to recurring_transactions_path
  end

  def restore
    @recurring_transaction = Current.family.recurring_transactions.accessible_by(Current.user).dismissed.find(params[:id])
    @recurring_transaction.undismiss!

    flash[:notice] = t("recurring_transactions.restored")
    redirect_to recurring_transactions_path
  end

  private

    def recurring_settings_params
      { recurring_transactions_disabled: params[:recurring_transactions_disabled] == "true" }
    end
end
