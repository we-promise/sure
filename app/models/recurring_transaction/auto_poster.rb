# Materializes a real `Entry` + `Transaction` from a `RecurringTransaction`
# template when its `next_expected_date` has arrived. Called by
# `PostDueRecurringTransactionsJob` on the daily cron.
#
# Idempotency: after a successful post, advances the recurring's
# `next_expected_date` via `record_occurrence!`. The job's query
# (`due_for_auto_post`) only picks up rows where
# `next_expected_date <= today`, so once advanced the row is no longer
# due and won't be re-posted. If the job runs multiple times in a day,
# the second run sees the already-advanced date and skips.
#
# Transfers are intentionally out of scope for V1 — a recurring transfer
# needs to create paired inflow/outflow entries + a `Transfer` row, which
# is its own coordination problem. The PORO returns `:skipped_transfer`
# in that case so the job can log it without dropping the row from the
# active set.
#
# This belongs under `app/models/recurring_transaction/` per Convention 2
# ("skinny controllers, fat models — almost everything in app/models/,
# avoid app/services/"). It's invoked from the job, not from a
# controller.
class RecurringTransaction::AutoPoster
  Result = Struct.new(:status, :entry, :reason, keyword_init: true) do
    def posted?
      status == :posted
    end
  end

  def initialize(recurring_transaction)
    @recurring = recurring_transaction
  end

  # Posts at most one entry for the current `next_expected_date`. Returns
  # a Result describing what happened. Never raises on the expected
  # skip paths (inactive, not due, no account, transfer) — those are
  # business outcomes, not errors. Unexpected exceptions still bubble
  # so the job's Sentry instrumentation catches them.
  def call
    return Result.new(status: :skipped_inactive, reason: "recurring transaction is not active") unless @recurring.active?
    return Result.new(status: :skipped_not_due, reason: "next_expected_date is in the future") if @recurring.next_expected_date.future?
    return Result.new(status: :skipped_no_account, reason: "recurring transaction has no source account") if @recurring.account_id.blank?
    return Result.new(status: :skipped_transfer, reason: "recurring transfers are not auto-posted in V1") if @recurring.transfer?

    entry = nil
    RecurringTransaction.transaction do
      entry = @recurring.account.entries.create!(
        date: @recurring.next_expected_date,
        name: display_name,
        amount: posting_amount,
        currency: @recurring.currency,
        entryable: Transaction.new(merchant_id: @recurring.merchant_id),
        source: "recurring_auto_post"
      )

      entry.lock_saved_attributes!
      entry.mark_user_modified!

      # Advance next_expected_date forward so the row is no longer "due"
      # on subsequent job runs in the same day.
      @recurring.record_occurrence!(@recurring.next_expected_date, posting_amount)
    end

    entry.sync_account_later

    Result.new(status: :posted, entry: entry)
  end

  private
    # Manual recurring rows with amount variance use the running average
    # so the posted entry tracks what the user actually sees in their
    # statements over time. Non-variance rows use the fixed template
    # amount as-is.
    def posting_amount
      if @recurring.manual? && @recurring.expected_amount_avg.present?
        @recurring.expected_amount_avg
      else
        @recurring.amount
      end
    end

    def display_name
      @recurring.merchant&.name || @recurring.name || "Scheduled transaction"
    end
end
