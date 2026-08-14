class RecurringOccurrencesController < ApplicationController
  layout "settings"

  before_action :set_occurrence

  # The dialog is delivered into the shared <turbo-frame id="modal"> (see
  # RecurringTransactionsController#edit for the two-frames trap).
  def show
    @candidate_query = params[:q].to_s.strip
    @candidates = candidate_entries

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
  rescue ArgumentError
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

    def allocator
      RecurringTransaction::Allocator.new(@occurrence)
    end

    def dialog_layout
      turbo_frame_request? ? false : "settings"
    end

    def redirect_after_action(message, alert: false)
      flash[alert ? :alert : :notice] = message
      target = bills_path

      respond_to do |format|
        format.html { redirect_to target }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, target) }
      end
    end

    # Entries a user would plausibly attach by hand: right account, right sign,
    # not already allocated here. Same-currency only in this list -- a
    # cross-currency attach goes through an explicit amount.
    #
    # Ordered by how close the amount is, not by how recent the transaction is.
    # A bill is nearly always settled by a charge for its own amount, so date
    # order buried the right answer: on a $6.44 bill with 77 candidates in the
    # window, all four near-amount matches sat outside the fifteen shown.
    #
    # A search looks past the date window entirely, because the payment being
    # hunted for is usually the one the window already excluded.
    def candidate_entries
      series = @occurrence.recurring_transaction
      base = series.account.present? ? series.account.entries : Current.family.entries
      sign = series.amount.negative? ? "entries.amount < 0" : "entries.amount > 0"

      scope = base
        .where(entryable_type: "Transaction")
        .where(currency: @occurrence.currency)
        .where(sign)
        .where.not(id: @occurrence.allocations.where.not(entry_id: nil).select(:entry_id))
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")

      unless series.transfer?
        scope = scope.where.not(transactions: { kind: Transaction::TRANSFER_KINDS })
      end

      scope = if @candidate_query.present?
        scope.where("entries.name ILIKE :q", q: "%#{ActiveRecord::Base.sanitize_sql_like(@candidate_query)}%")
      else
        scope.where(date: (@occurrence.due_on - 40)..[ @occurrence.due_on + 40, Date.current ].min)
      end

      scope.order(candidate_relevance_sql).limit(15)
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
