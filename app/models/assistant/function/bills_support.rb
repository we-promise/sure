# frozen_string_literal: true

# Shared plumbing for the Bills tools. The Bills pages sit behind a per-family
# feature gate and a per-user account-access scope; tool calls never pass
# through those controllers, so every tool re-checks both here.
#
# Status vocabulary: these tools speak the UI's lifecycle words, not raw
# storage. Nothing in the app writes the stored value "paused" (the Pause
# button stores "inactive"), so "paused" here means the inactive+paused set,
# exactly as the All-bills filter treats it.
module Assistant::Function::BillsSupport
  # Mirrors BillsController::LIFECYCLE_STATUSES with the two review states.
  STATUS_VOCABULARY = {
    "active" => %w[active],
    "suggested" => %w[suggested],
    "paused" => %w[inactive paused],
    "ended" => %w[ended]
  }.freeze

  private
    def recurring_disabled?
      family.recurring_transactions_disabled?
    end

    def recurring_disabled_result
      {
        error: "Bills & recurring transactions are disabled for this family",
        hint: "Do not retry. Tell the user this feature is switched off under Settings -> Recurring transactions, and answer from transaction data instead."
      }
    end

    def accessible_series
      family.recurring_transactions.accessible_by(user)
    end

    def find_series(id)
      unless valid_uuid?(id)
        return [ nil, {
          error: "bill_id is not a valid id",
          hint: "Pass the exact id returned by get_bills."
        } ]
      end

      # find (not find_by): a missing or foreign id raises RecordNotFound,
      # which the tool caller converts into an error+hint result.
      [ accessible_series.find(id), nil ]
    end

    # The write tools' lookup. Reading a shared bill is fine; changing it is
    # not: sharing is per account, so a read-only share must not mutate the
    # series, exactly as RecurringTransactionsController#ensure_series_writable
    # enforces for the pages. Accountless series carry no account gate. The
    # bill is already visible to this user, so naming the reason leaks nothing.
    def find_writable_series(id)
      series, error = find_series(id)
      return [ nil, error ] if error

      if series.account_id.present? && !Account.writable_by(user).where(id: series.account_id).exists?
        return [ nil, {
          error: "#{series.display_name} is on an account shared with you read-only",
          hint: "You can read this bill but not change it. Do not retry."
        } ]
      end

      [ series, nil ]
    end

    def display_status(series)
      case series.status
      when "inactive", "paused" then "paused"
      else series.status
      end
    end

    def serialize_series(series)
      detection = RecurringTransaction::FrequencyPreset.detect(series)

      {
        id: series.id,
        name: series.display_name,
        bill_type: series.bill_type,
        status: display_status(series),
        amount: series.amount_money.abs.format,
        currency: series.currency,
        frequency: detection.key || "custom",
        next_due_date: series.next_due_date&.iso8601,
        autopay: series.autopay,
        detected_automatically: !series.manual,
        category: series.category&.name,
        account: account_ref(series.account),
        destination_account: account_ref(series.destination_account),
        monthly_equivalent: series.monthly_equivalent_amount&.abs&.format,
        payment_url: series.payment_url
      }.compact
    end

    def serialize_occurrence(occurrence)
      return nil if occurrence.nil?

      # Read once, derive locally: resolved_expected_amount is unmemoized and
      # can cost two queries per call under the `last` amount strategy.
      expected = occurrence.resolved_expected_amount
      paid = occurrence.confirmed_allocated

      {
        due_on: occurrence.due_on.iso8601,
        effective_due_on: occurrence.effective_due_on.iso8601,
        state: occurrence.derived_state.to_s,
        expected: Money.new(expected, occurrence.currency).format,
        paid: Money.new(paid, occurrence.currency).format,
        remaining: Money.new([ expected - paid, 0 ].max, occurrence.currency).format,
        partially_paid: occurrence.scheduled? && paid.positive? && paid < expected
      }
    end

    def account_ref(account)
      return nil if account.nil?

      { id: account.id, name: account.name }
    end

    # One grouped SUM for the given occurrences, injected through the same
    # cache the list views use, so serialization issues no per-row queries.
    def preload_allocation_sums(occurrences)
      rows = occurrences.compact
      return if rows.empty?

      sums = RecurringAllocation.confirmed
                                .where(recurring_occurrence_id: rows.map(&:id))
                                .group(:recurring_occurrence_id)
                                .sum(:allocated_amount)

      rows.each { |occurrence| occurrence.cached_confirmed_allocated = sums[occurrence.id] || 0 }
    end

    # current_occurrence resolved from the preloaded association instead of
    # the model's per-series queries (100 series would mean 100 queries).
    def current_occurrence_from_loaded(series)
      occurrences = series.recurring_occurrences
      occurrences.select(&:scheduled?).min_by(&:due_on) ||
        occurrences.max_by(&:due_on)
    end

    # Spend commitments only: income is not spend and a transfer moves money
    # rather than spending it, so both stay out of any totals row.
    def spend_series?(series)
      !%w[income transfer].include?(series.bill_type)
    end

    # How far a price moved, as a signed percent of what it was. nil when
    # there is no previous amount to compare against.
    def percent_change(previous_amount, new_amount)
      previous = previous_amount.abs
      return nil if previous.zero?

      (((new_amount.abs - previous) / previous) * 100).round(1).to_f
    end
end
