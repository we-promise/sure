# Bills subsystem: this controller gained the declared-bill and declared-income
# create paths, editable identity and frequency, suggestion confirm/dismiss, and
# schedule pinning on a hand-set cadence.
class RecurringTransactionsController < ApplicationController
  include RecurringFeatureGuardable

  layout "settings"

  # Small on purpose: the picker narrows by searching, not by paging, and a
  # fixed cap keeps the dialog free of pagination (whose shared partial
  # targets _top and cannot live inside a turbo frame).
  PICKER_SHOWN = 20

  # The declare, edit and suggestion paths shipped with Bills and sit behind
  # its preview gate like every other Bills surface. The actions that predate
  # Bills (index, toggle_status, destroy, update_settings, identify, cleanup)
  # keep their historical reach.
  before_action :ensure_recurring_enabled, only: %i[new create edit update confirm dismiss]
  before_action :set_recurring_transaction, only: %i[edit update toggle_status destroy confirm dismiss]
  before_action :ensure_series_writable, only: %i[update toggle_status destroy confirm dismiss]

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
    first_confirmation = @recurring_transaction.suggested?
    @recurring_transaction.update!(status: "active")

    # A just-confirmed bill shows its lived history rather than starting
    # blank. Guarded so a replayed POST does not re-run the backfill; the
    # matcher pass inside is family-wide on purpose (exact-tier, idempotent,
    # and scoping it would need a parallel Matcher entry point). Taken under
    # the family lock so it cannot interleave with a running pipeline; when
    # the lock is held the backfill is skipped and the confirm still succeeds.
    if first_confirmation
      RecurringTransaction::Pipeline.with_family_lock(Current.family.id) do
        RecurringTransaction::HistoryBackfiller.new(
          Current.family,
          months: RecurringTransaction::Pipeline::FIRST_RUN_BACKFILL_MONTHS,
          series_scope: Current.family.recurring_transactions.where(id: @recurring_transaction.id)
        ).run!
      end
    end

    flash[:notice] = t("recurring_transactions.confirmed")
    redirect_back_or_to recurring_transactions_path
  end

  def dismiss
    @recurring_transaction.update!(status: "ended")

    flash[:notice] = t("recurring_transactions.dismissed")
    redirect_back_or_to recurring_transactions_path
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
    # User-triggered detection always reconstructs history; the backfiller is
    # idempotent. nil means another run already holds the family lock.
    result = RecurringTransaction::Pipeline.new(Current.family).run_with_lock!(backfill: true)

    respond_to do |format|
      format.html do
        flash[:notice] =
          if result.nil?
            t("recurring_transactions.identify_already_running")
          else
            t("recurring_transactions.identified", count: result)
          end
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

    # "Not seeing what you're looking for?": a picker over every transaction,
    # for when the detected candidates don't include the charge on the
    # statement in the user's hand. Same URL and frame as the dialog it
    # replaces, and a result row is just the entry_id prefill link the
    # candidate strip already uses.
    if params[:picker].present?
      @is_income = income
      @picker_query = params[:q].to_s.strip
      @picker_entries = picker_entries(income: income)
      @picker_capped = @picker_entries.size == PICKER_SHOWN
      @claimed_by = claimed_series_names(@picker_entries)
      return render :pick_entry, layout: dialog_layout
    end

    @recurring_transaction = Current.family.recurring_transactions.new(
      # Paychecks default to the most common pay cadence; bills to monthly.
      frequency_preset: income ? "biweekly" : "monthly",
      first_due_on: Date.current
    )
    @recurring_transaction.is_income = income

    # Accessible, not merely same-family: prefilling reads the entry's name,
    # amount and account straight back to the user.
    if (entry = Current.accessible_entries.find_by(id: params[:entry_id]))
      prefill_recurring_from_entry(entry)
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

    # apply_editable_identity flags a bad account id; save would wipe that
    # error while validating, so it is checked first.
    if @recurring_transaction.errors.none? && @recurring_transaction.save
      applied = apply_payment_url_to_siblings

      flash[:notice] = if applied.positive?
        t(".success_with_siblings", count: applied)
      else
        t(".success")
      end

      respond_to do |format|
        format.html { redirect_back_or_to recurring_transactions_path }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, safe_return_path(fallback: recurring_transactions_path)) }
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

    # A detected row is removed by tombstoning it rather than deleting it: the
    # pattern is still in the bank data, so a hard delete lasts only until the
    # next sync rebuilds it. `ended` is the marker dismissing a suggestion
    # already leaves, and the Identifier will not claim or recreate one.
    #
    # A hand-declared bill has no pattern behind it, so nothing would bring it
    # back and it is deleted outright.
    if @recurring_transaction.manual?
      @recurring_transaction.destroy!
    else
      @recurring_transaction.update!(status: "ended")
    end

    flash[:notice] = t(income ? "recurring_transactions.deleted_income" : "recurring_transactions.deleted")
    redirect_back_or_to bills_path
  end

  protected

    # Seeds the dialog's model from an existing transaction. Shared with the
    # smart-fill path, so a failed suggestion still leaves the user exactly
    # where the plain prefill would have.
    def prefill_recurring_from_entry(entry)
      @recurring_transaction.name = entry.entryable.try(:merchant)&.name.presence || entry.name
      @recurring_transaction.amount = entry.amount.abs
      @recurring_transaction.account_id = entry.account_id
      # A negative entry is an inflow: pre-fill as income, not as a bill.
      @recurring_transaction.is_income = true if entry.amount.negative?
      @recurring_transaction.first_due_on =
        RecurringTransaction::Schedule.new(expected_day_of_month: entry.date.day).next_occurrence_from_today
    end

  private

    # Sign-filtered detected patterns not yet covered by any series, mapped
    # to what the picker renders. Each candidate carries its latest entry's
    # id so selection can ride the existing entry_id prefill path. Patterns
    # are family-wide, so they are filtered to the accounts this user can
    # actually reach.
    def declare_candidates(income:)
      identifier = RecurringTransaction::Identifier.new(Current.family)
      accessible_ids = Current.user.accessible_accounts.pluck(:id)

      patterns = if income
        # Already sorted heaviest-source-first, so the paycheck leads.
        identifier.income_source_candidates
      else
        identifier.candidate_patterns(sign: :outflow)
                  .sort_by { |pattern| pattern[:last_occurrence_date] }
                  .reverse
      end

      patterns
        .select { |pattern| accessible_ids.include?(pattern[:account_id]) }
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

    # Every transaction a bill could start from: accessible (not merely
    # same-family), the right sign for the mode, transfers and excluded rows
    # out. No target amount exists yet, so recency is the only honest order.
    # Merchant names are matched because detected entry names are often bank
    # blobs; the search stays picker-local so the app-wide EntrySearch
    # semantics (and the transactions index query plan) are untouched.
    def picker_entries(income:)
      scope = Current.accessible_entries
        .where(entryable_type: "Transaction")
        .where(excluded: false)
        .where(income ? "entries.amount < 0" : "entries.amount > 0")
        .merge(Entry.excluding_split_parents)
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
        .where.not(transactions: { kind: Transaction::TRANSFER_KINDS })

      if @picker_query.present?
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(@picker_query)}%"
        scope = scope
          .joins("LEFT JOIN merchants ON merchants.id = transactions.merchant_id")
          .where("entries.name ILIKE :q OR entries.notes ILIKE :q OR merchants.name ILIKE :q", q: pattern)
      end

      scope.order(date: :desc, created_at: :desc)
           .limit(PICKER_SHOWN)
           .preload(:account)
    end

    # Entries already backing a bill get a "Part of X" chip rather than being
    # hidden: hiding lies, but starting a new bill from a claimed charge
    # usually means a duplicate in the making.
    def claimed_series_names(entries)
      RecurringAllocation.confirmed
        .joins(:recurring_occurrence)
        .where(entry_id: entries.map(&:id))
        .includes(recurring_occurrence: { recurring_transaction: :merchant })
        .to_h { |a| [ a.entry_id, a.recurring_occurrence.recurring_transaction.display_name ] }
    end

    def set_recurring_transaction
      @recurring_transaction = Current.family.recurring_transactions
                                      .accessible_by(Current.user)
                                      .find(params[:id])
    end

    # Reading a shared bill is fine; changing it is not. Sharing is per
    # account, so a read-only account share must not mutate the series.
    # Accountless series carry no account gate. Same contract as
    # RecurringOccurrencesController#ensure_series_writable.
    def ensure_series_writable
      return if @recurring_transaction.account_id.nil?
      return if Account.writable_by(Current.user).where(id: @recurring_transaction.account_id).exists?

      raise ActiveRecord::RecordNotFound
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
      RecurringTransaction::DeclaredBill.new(
        family: Current.family,
        user: Current.user,
        attrs: new_recurring_transaction_params
      ).build
    end

    def save_declared_bill
      RecurringTransaction::DeclaredBill.save(@recurring_transaction)
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
        # Blank means "any account"; a present id that does not resolve must
        # not silently detach the bill from its account. Writable, not merely
        # visible: attaching a series to an account changes what that
        # account's owners see, so a read-only share cannot be a destination.
        if attrs[:account_id].blank?
          @recurring_transaction.account = nil
        elsif (account = Account.writable_by(Current.user).find_by(id: attrs[:account_id]))
          @recurring_transaction.account = account
        else
          @recurring_transaction.errors.add(:account, :invalid)
        end
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
    # Scoped to what this user can WRITE, not merely see: a series on an account
    # shared read-only must not be rewritten by the copy, and accountless series
    # carry no account gate. Merchant-less rows are skipped entirely, because
    # their only identity is a free-text name that says nothing about where to pay.
    # `update_all` is deliberate: the value being copied was already normalized and
    # validated on the source record, and a row-by-row save would let an unrelated
    # pre-existing validation failure on a legacy sibling abort the whole copy.
    def apply_payment_url_to_siblings
      return 0 unless params[:apply_to_siblings] == "1"
      # Clearing the link is a statement about this bill only: copying a blank
      # over the siblings would erase links that were never wrong.
      return 0 if @recurring_transaction.payment_url.blank?

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
                     .where(account_id: Account.writable_by(Current.user).pluck(:id) + [ nil ])
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
