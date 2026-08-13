class RecurringTransactionsController < ApplicationController
  layout "settings"

  before_action :set_recurring_transaction, only: %i[edit update toggle_status destroy]

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

  # The dialog is delivered into the shared <turbo-frame id="modal"> that every page
  # layout already renders empty. Responding with the full "settings" layout would put
  # two frames with that id in one response, and Turbo matches the empty one first, so
  # the dialog never opens. Drop the layout for frame requests, as `categories#merge`
  # does, and keep it for a direct visit to the URL.
  def edit
    assign_frequency_form_state
    @sibling_count = sibling_scope.count

    render layout: dialog_layout
  end

  def update
    @recurring_transaction.assign_attributes(recurring_transaction_params)
    apply_frequency_preset

    if @recurring_transaction.save
      applied = apply_payment_url_to_siblings

      flash[:notice] = if applied.positive?
        t(".success_with_siblings", count: applied)
      else
        t(".success")
      end

      redirect_target_url = request.referer || recurring_transactions_path
      respond_to do |format|
        format.html { redirect_back_or_to recurring_transactions_path }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, redirect_target_url) }
      end
    else
      @sibling_count = sibling_scope.count

      render :edit, status: :unprocessable_entity, layout: dialog_layout
    end
  end

  def toggle_status
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
    @recurring_transaction.destroy!

    flash[:notice] = t("recurring_transactions.deleted")
    redirect_to recurring_transactions_path
  end

  private

    def dialog_layout
      turbo_frame_request? ? false : "settings"
    end

    def set_recurring_transaction
      @recurring_transaction = Current.family.recurring_transactions
                                      .accessible_by(Current.user)
                                      .find(params[:id])
    end

    def recurring_transaction_params
      params.require(:recurring_transaction).permit(
        :payment_url, :autopay, :notes,
        :frequency_preset, :frequency_day_of_month, :frequency_second_day_of_month,
        :frequency_weekday, :frequency_month_of_year
      )
    end

    # Pre-fills the frequency picker's virtual attributes from the series'
    # rules so the form shows the current cadence.
    def assign_frequency_form_state
      detection = RecurringTransaction::FrequencyPreset.detect(@recurring_transaction)

      @recurring_transaction.frequency_preset = detection.key
      @recurring_transaction.frequency_day_of_month = detection.day_of_month
      @recurring_transaction.frequency_second_day_of_month = detection.second_day_of_month
      @recurring_transaction.frequency_weekday = detection.weekday
      @recurring_transaction.frequency_month_of_year = detection.month_of_year
    end

    def apply_frequency_preset
      RecurringTransaction::FrequencyPreset.apply(
        @recurring_transaction,
        preset: @recurring_transaction.frequency_preset,
        day_of_month: @recurring_transaction.frequency_day_of_month,
        second_day_of_month: @recurring_transaction.frequency_second_day_of_month,
        weekday: @recurring_transaction.frequency_weekday,
        month_of_year: @recurring_transaction.frequency_month_of_year
      )
    end

    # One merchant routinely owns several bills (three separate Twitch subscriptions,
    # for example), and they all pay at the same portal. Opting in copies the link to
    # the caller's other bills for that merchant so the user types it once.
    #
    # Scoped through `accessible_by` so this never writes to a bill the user cannot
    # already see, and skipped entirely for merchant-less rows, whose only identity is
    # a free-text name that says nothing about where to pay.
    # `update_all` is deliberate: the value being copied was already normalized and
    # validated on the source record, and a row-by-row save would let an unrelated
    # pre-existing validation failure on a legacy sibling abort the whole copy.
    def apply_payment_url_to_siblings
      return 0 unless params[:apply_to_siblings] == "1"

      sibling_scope.update_all(
        payment_url: @recurring_transaction.payment_url,
        updated_at: Time.current
      )
    end

    # One biller commonly owns several bills that all pay at the same portal (three
    # separate subscriptions to one service, say). Siblings are found the same way
    # `RecurringTransaction::Identifier` groups patterns in the first place: by
    # merchant when there is one, and by exact name otherwise. Matching on merchant
    # alone would miss most rows, because auto-detection leaves `merchant_id` null
    # whenever the provider feed gave it nothing to match against.
    def sibling_scope
      scope = Current.family.recurring_transactions
                     .accessible_by(Current.user)
                     .where.not(id: @recurring_transaction.id)

      if @recurring_transaction.merchant_id.present?
        scope.where(merchant_id: @recurring_transaction.merchant_id)
      elsif @recurring_transaction.name.present?
        scope.where(merchant_id: nil, name: @recurring_transaction.name)
      else
        RecurringTransaction.none
      end
    end

    def recurring_settings_params
      { recurring_transactions_disabled: params[:recurring_transactions_disabled] == "true" }
    end
end
