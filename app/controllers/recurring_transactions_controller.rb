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

  def toggle_auto_post
    @recurring_transaction = Current.family.recurring_transactions.accessible_by(Current.user).find(params[:id])
    enabling = !@recurring_transaction.auto_post?

    # Transfers are not auto-posted in V1 — the AutoPoster returns
    # :skipped_transfer for them. Allowing the toggle to enable on a
    # transfer would set a flag that the job silently ignores, which
    # is worse UX than refusing the toggle outright. Disabling is
    # always allowed (covers legacy rows where the flag might somehow
    # be true).
    if enabling && @recurring_transaction.transfer?
      respond_to do |format|
        format.html do
          flash[:alert] = t("recurring_transactions.auto_post_transfer_not_allowed")
          redirect_to recurring_transactions_path
        end
      end
      return
    end

    @recurring_transaction.update!(auto_post: enabling)

    message = @recurring_transaction.auto_post? ?
      t("recurring_transactions.auto_post_enabled") :
      t("recurring_transactions.auto_post_disabled")

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
      { recurring_transactions_disabled: params[:recurring_transactions_disabled] == "true" }
    end
end
