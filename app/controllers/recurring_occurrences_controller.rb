class RecurringOccurrencesController < ApplicationController
  include RecurringFeatureGuardable

  layout "settings"

  before_action :ensure_recurring_enabled
  before_action :set_occurrence
  before_action :ensure_series_writable, only: %i[mark_paid skip reopen snooze override_amount]

  # The dialog is delivered into the shared <turbo-frame id="modal"> (see
  # RecurringTransactionsController#edit for the two-frames trap).
  def show
    @candidate_query = params[:q].to_s.strip
    @pending_suggestion = @occurrence.allocations.suggested.includes(:entry).first
    @ranked_candidates = ranked_candidates
    ranked_ids = @ranked_candidates.map { |entry, _| entry.id }
    # The amount-nearness list is the fallback, so it must not repeat what the
    # ranked list promoted. The extra fetch keeps it full after subtraction.
    @other_entries = candidate_entries.reject { |entry| ranked_ids.include?(entry.id) }.first(FALLBACK_SHOWN)

    render layout: dialog_layout
  end

  def mark_paid
    allocator.mark_paid!
    redirect_after_action t(".success")
  end

  def skip
    @occurrence.skip!
    redirect_after_action t(".success")
  end

  def reopen
    @occurrence.reopen!
    redirect_after_action t(".success")
  end

  def snooze
    until_date = Date.parse(params.require(:until))
    @occurrence.snooze!(until_date)
    redirect_after_action t(".success", date: l(until_date, format: :long))
  # TypeError covers non-scalar params (until[]=...), which Date.parse raises
  # on before ArgumentError gets a chance; both are the same user mistake.
  rescue ArgumentError, TypeError
    redirect_after_action t(".invalid_date"), alert: true
  end

  def override_amount
    @occurrence.override_amount!(params[:amount])
    redirect_after_action t(".success")
  end

  private
    def set_occurrence
      @occurrence = Current.family.recurring_occurrences
                           .joins(:recurring_transaction)
                           .merge(RecurringTransaction.accessible_by(Current.user))
                           .find(params[:id])
    end

    # Reading a shared bill is fine; changing its payment state is not. Sharing
    # is per account, so a read-only account share must not mutate. Accountless
    # series carry no account gate.
    def ensure_series_writable
      series = @occurrence.recurring_transaction
      return if series.account_id.nil?
      return if Account.writable_by(Current.user).where(id: series.account_id).exists?

      raise ActiveRecord::RecordNotFound
    end

    def allocator
      RecurringTransaction::Allocator.new(@occurrence)
    end

    def redirect_after_action(message, alert: false)
      flash[alert ? :alert : :notice] = message
      target = bills_path

      respond_to do |format|
        format.html { redirect_to target }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, target) }
      end
    end

    # How many entries the ranked pass will score in Ruby, and how many of each
    # list survives to the view.
    RANKED_SCAN_LIMIT = 200
    RANKED_SHOWN = 6
    FALLBACK_SHOWN = 15

    # Hard filters both lists share: right account, sign, currency, a real
    # transaction, not already allocated to THIS occurrence. Cross-currency
    # attaches go through an explicit amount instead.
    #
    # The raw join is load-bearing: every `where(transactions: {...})` below is
    # only legal because it puts that table in the query.
    def candidate_scope
      series = @occurrence.recurring_transaction
      # Accountless bills fall back to the accounts this user can see, never
      # the whole family: sharing is per account, and the drawer would
      # otherwise print entries from accounts that were never shared.
      base = if series.account.present?
        series.account.entries
      else
        Current.family.entries.where(account_id: Account.accessible_by(Current.user).select(:id))
      end
      sign = series.amount.negative? ? "entries.amount < 0" : "entries.amount > 0"

      scope = base
        .where(entryable_type: "Transaction")
        .where(currency: @occurrence.currency)
        .where(sign)
        .where.not(id: @occurrence.allocations.where.not(entry_id: nil).select(:entry_id))
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")

      return scope if series.transfer?

      scope.where.not(transactions: { kind: Transaction::TRANSFER_KINDS })
    end

    # Shared by both lists so they cannot disagree about which dates exist.
    def candidate_window
      (@occurrence.due_on - 40)..[ @occurrence.due_on + 40, Date.current ].min
    end

    # Ranked by the same engine that decides auto-links, so the picker and the
    # pipeline agree on what a match is, and the rejection table is honoured.
    #
    # Entries already allocated to another occurrence are deliberately kept: one
    # charge can legitimately pay two bills, which is why
    # Allocator#guard_entry_capacity! exists. Over-allocation is refused at
    # write time, never hidden at read time.
    def ranked_candidates
      series = @occurrence.recurring_transaction
      matcher = RecurringTransaction::Matcher.new(Current.family)

      scope = candidate_scope
        .where(date: candidate_window)
        .where(excluded: false)
        .where.not(id: RecurringMatchRejection.where(recurring_transaction: series).select(:entry_id))
        # preload, not includes: entryable is polymorphic so it can never be
        # joined, and naming it keeps the raw transactions join above out of
        # Rails' eager-load machinery.
        .preload(:entryable)
        .limit(RANKED_SCAN_LIMIT)

      scope = if series.merchant_id.present?
        scope.where(transactions: { merchant_id: series.merchant_id })
      else
        patterns = matcher_name_patterns(series)
        return [] if patterns.empty?

        scope.where("entries.name ILIKE ANY (ARRAY[?])", patterns)
      end

      scored = scope.filter_map do |entry|
        explanation = matcher.explain(@occurrence, entry)
        [ entry, explanation ] if explanation
      end

      scored.sort_by { |_entry, explanation| -explanation.confidence }.first(RANKED_SHOWN)
    end

    # The names the matcher itself would recognize: the series' own name plus
    # any alias a manual attach has taught it.
    def matcher_name_patterns(series)
      ([ series.name ] + Array(series.matcher_hints["name_aliases"]))
        .compact_blank
        .map { |name| "%#{ActiveRecord::Base.sanitize_sql_like(name)}%" }
    end

    # Entries a user would plausibly attach by hand, ordered by how close the
    # amount is rather than by how recent the transaction is. A bill is nearly
    # always settled by a charge for its own amount, so date order buried the
    # right answer: on a $6.44 bill with 77 candidates in the window, all four
    # near-amount matches sat outside the fifteen shown.
    #
    # This is the fallback now -- what you browse when the ranked list did not
    # have it. A search looks past the date window entirely, because the
    # payment being hunted for is usually the one the window already excluded.
    def candidate_entries
      scope = if @candidate_query.present?
        candidate_scope.where("entries.name ILIKE :q", q: "%#{ActiveRecord::Base.sanitize_sql_like(@candidate_query)}%")
      else
        candidate_scope.where(date: candidate_window)
      end

      scope.order(candidate_relevance_sql).limit(FALLBACK_SHOWN + RANKED_SHOWN)
    end

    def candidate_relevance_sql
      remaining = @occurrence.remaining_amount
      target = remaining.positive? ? remaining : @occurrence.resolved_expected_amount

      Arel.sql(
        ActiveRecord::Base.sanitize_sql_array([
          "ABS(ABS(entries.amount) - ?) ASC, ABS(entries.date - ?) ASC, entries.date DESC",
          target, @occurrence.due_on
        ])
      )
    end
end
