# Bills subsystem: this controller gained the declared-bill and declared-income
# create paths, editable identity and frequency, suggestion confirm/dismiss, and
# schedule pinning on a hand-set cadence.
class RecurringTransactionsController < ApplicationController
  layout "settings"

  before_action :set_recurring_transaction, only: %i[edit update toggle_status destroy confirm dismiss]

  def index
    scope = Current.family.recurring_transactions
                  .accessible_by(Current.user)
                  .includes(:merchant)

    # Fresh detections wait in their own review strip until confirmed; they
    # are not real bills yet and would only be noise inside the main table.
    @suggested = scope.suggested.order(next_expected_date: :asc)
    @recurring_transactions = scope.where.not(status: :suggested)
                                   .order(status: :asc, next_expected_date: :asc)
    @family = Current.family
  end

  # Detection proposes, the user disposes: confirming makes the suggestion a
  # real, active bill; dismissing tombstones it as `ended`, which the
  # Identifier treats as "never suggest this again".
  def confirm
    @recurring_transaction.update!(status: "active")

    flash[:notice] = t("recurring_transactions.confirmed")
    redirect_to recurring_transactions_path
  end

  def dismiss
    @recurring_transaction.update!(status: "ended")

    flash[:notice] = t("recurring_transactions.dismissed")
    redirect_to recurring_transactions_path
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

    # Manual-first parity with the sync pipeline: a user with no bank feed
    # (or a fresh install reviewing history) gets the same materialize +
    # reconcile the post-sync job performs.
    Current.family.recurring_transactions.active.find_each do |series|
      RecurringTransaction::OccurrenceGenerator.new(series).generate!
    end
    matcher = RecurringTransaction::Matcher.new(Current.family)
    matcher.repair_orphans!
    matcher.run!
    RecurringTransaction::PriceChangeDetector.new(Current.family).detect!

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

  # Optionally pre-filled from an existing transaction (entry_id param): the
  # fastest declare path for a bill that already hits the ledger -- name,
  # amount, account and a projected next-due all come from the entry.
  def new
    income = params[:income].present?
    @recurring_transaction = Current.family.recurring_transactions.new(
      # Paychecks default to the most common pay cadence; bills to monthly.
      frequency_preset: income ? "biweekly" : "monthly",
      first_due_on: Date.current
    )
    @recurring_transaction.is_income = income

    # Accessible, not merely same-family: prefilling reads the entry's name,
    # amount and account straight back to the user.
    if (entry = Current.accessible_entries.find_by(id: params[:entry_id]))
      @recurring_transaction.name = entry.entryable.try(:merchant)&.name.presence || entry.name
      @recurring_transaction.amount = entry.amount.abs
      @recurring_transaction.account_id = entry.account_id
      # A negative entry is an inflow: pre-fill as income, not as a bill.
      @recurring_transaction.is_income = true if entry.amount.negative?
      @recurring_transaction.first_due_on =
        RecurringTransaction::Schedule.new(expected_day_of_month: entry.date.day).next_occurrence_from_today
    else
      # Fresh dialog: offer detected-but-undeclared recurring shapes as
      # optional starting points. Picking one reloads the dialog prefilled
      # through the entry_id path above; it never replaces manual entry.
      @candidates = declare_candidates(income: income)
    end

    render layout: dialog_layout
  end

  # Declared bills are the manual-first path: Name, Amount, Due date,
  # Frequency, done. The due date carries the day-of-month / weekday detail
  # the frequency needs, so the form never asks twice.
  def create
    @recurring_transaction = build_declared_bill

    if @recurring_transaction.errors.none? && save_declared_bill
      flash[:notice] = @recurring_transaction.typed_income? ? t(".success_income") : t(".success")

      respond_to do |format|
        format.html { redirect_to bills_path }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, bills_path) }
      end
    else
      render :new, status: :unprocessable_entity, layout: dialog_layout
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
    apply_editable_identity
    apply_frequency_preset

    if @recurring_transaction.typed_installment? && @recurring_transaction.end_after_count.present?
      @recurring_transaction.end_mode = "after_count"
      @recurring_transaction.anchor_date ||= @recurring_transaction.last_occurrence_date
    end

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
    income = @recurring_transaction.typed_income?
    @recurring_transaction.destroy!

    flash[:notice] = t(income ? "recurring_transactions.deleted_income" : "recurring_transactions.deleted")
    redirect_back_or_to bills_path
  end

  private

    # Sign-filtered detected patterns not yet covered by any series, mapped
    # to what the picker renders. Each candidate carries its latest entry's
    # id so selection can ride the existing entry_id prefill path.
    def declare_candidates(income:)
      identifier = RecurringTransaction::Identifier.new(Current.family)

      patterns = if income
        # Already sorted heaviest-source-first, so the paycheck leads.
        identifier.income_source_candidates
      else
        identifier.candidate_patterns(sign: :outflow)
                  .sort_by { |pattern| pattern[:last_occurrence_date] }
                  .reverse
      end

      patterns
        .first(8)
        .map do |pattern|
          latest = pattern[:entries].max_by(&:date)

          {
            name: pattern[:name].presence || latest.entryable.try(:merchant)&.name.presence || latest.name,
            amount: pattern[:expected_amount_avg].abs,
            currency: pattern[:currency],
            last_date: pattern[:last_occurrence_date],
            count: pattern[:occurrence_count],
            entry_id: latest.id
          }
        end
    end

    def dialog_layout
      turbo_frame_request? ? false : "settings"
    end

    def set_recurring_transaction
      @recurring_transaction = Current.family.recurring_transactions
                                      .accessible_by(Current.user)
                                      .find(params[:id])
    end

    # name, amount and account are handled by apply_editable_identity rather
    # than listed here: the account has to be one this user can actually reach,
    # and the amount carries the series' sign convention. Neither survives a
    # raw permit.
    def recurring_transaction_params
      params.require(:recurring_transaction).permit(
        :payment_url, :autopay, :notes, :bill_type, :category_id,
        :renews_on, :trial_ends_on, :cancelled_on, :end_after_count,
        :frequency_preset, :frequency_day_of_month, :frequency_second_day_of_month,
        :frequency_weekday, :frequency_month_of_year
      )
    end

    def new_recurring_transaction_params
      params.require(:recurring_transaction).permit(
        :name, :amount, :account_id, :first_due_on, :frequency_preset,
        :payment_url, :autopay, :notes, :is_income
      )
    end

    def build_declared_bill
      attrs = new_recurring_transaction_params
      account = Current.user.accessible_accounts.find_by(id: attrs[:account_id])
      due = Date.parse(attrs[:first_due_on].to_s) rescue nil

      is_income = ActiveModel::Type::Boolean.new.cast(attrs[:is_income]) || false
      amount = BigDecimal(attrs[:amount].to_s.presence || "0").abs
      amount = -amount if is_income

      recurring = Current.family.recurring_transactions.new(
        name: attrs[:name],
        amount: amount,
        bill_type: is_income ? "income" : "bill",
        account: account,
        currency: account&.currency || Current.family.currency,
        payment_url: attrs[:payment_url],
        autopay: ActiveModel::Type::Boolean.new.cast(attrs[:autopay]) || false,
        notes: attrs[:notes],
        status: "active",
        manual: true,
        occurrence_count: 0
      )
      recurring.frequency_preset = attrs[:frequency_preset]
      recurring.first_due_on = attrs[:first_due_on]

      if due.nil?
        recurring.errors.add(:base, t("recurring_transactions.create.due_date_required"))
        return recurring
      end

      recurring.expected_day_of_month = due.day
      recurring.anchor_date = due
      recurring.last_occurrence_date = due
      recurring.next_expected_date = due

      RecurringTransaction::FrequencyPreset.apply(
        recurring,
        preset: attrs[:frequency_preset],
        day_of_month: due.day,
        weekday: due.wday,
        month_of_year: due.month
      )

      recurring
    end

    def save_declared_bill
      @recurring_transaction.save
    rescue ActiveRecord::RecordNotUnique
      # A series for this identifier already exists; a second legitimate one
      # (another tier from the same biller) is distinguished by its amount.
      @recurring_transaction.dedup_scope = @recurring_transaction.amount.to_d.to_s("F")
      @recurring_transaction.save
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

    # A bill outliving its own price is the normal case, and the only way to
    # record a rise used to be delete-and-recreate, which takes the occurrences
    # and allocations with it. So name, amount and account are editable, but
    # resolved rather than mass-assigned:
    #
    #   account  must be one this user can reach, or a crafted account_id
    #            would point a bill at another family's account
    #   amount   is stored negative for income, so assigning the raw field
    #            would flip a paycheck into a bill
    #
    # first_due_on stays create-only. It seeds the schedule and does nothing on
    # a persisted series, so offering it would be a field that silently fails.
    # The day a bill falls due is edited through the frequency picker.
    #
    # Currency deliberately does not follow the account: it shapes the schedule
    # and is tied to existing allocations, and the allocator already converts
    # cross-currency payments.
    def apply_editable_identity
      attrs = params.require(:recurring_transaction)

      @recurring_transaction.name = attrs[:name] if attrs.key?(:name)

      if attrs[:amount].present?
        magnitude = attrs[:amount].to_d.abs
        @recurring_transaction.amount =
          @recurring_transaction.typed_income? ? -magnitude : magnitude
      end

      if attrs.key?(:account_id)
        @recurring_transaction.account =
          Current.user.accessible_accounts.find_by(id: attrs[:account_id])
      end
    end

    def apply_frequency_preset
      changed = RecurringTransaction::FrequencyPreset.apply(
        @recurring_transaction,
        preset: @recurring_transaction.frequency_preset,
        day_of_month: @recurring_transaction.frequency_day_of_month,
        second_day_of_month: @recurring_transaction.frequency_second_day_of_month,
        weekday: @recurring_transaction.frequency_weekday,
        month_of_year: @recurring_transaction.frequency_month_of_year
      )

      # A hand-set cadence is intent, not a guess for detection to correct.
      @recurring_transaction.pin_schedule if changed
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
