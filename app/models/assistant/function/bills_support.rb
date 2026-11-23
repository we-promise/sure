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

  BANK_REFERENCE_DESCRIPTION = "A stable token from the bank's payment note (Verwendungszweck) for this bill, " \
                               "e.g. a contract or customer number. A payment on the bill's account whose note " \
                               "contains it matches this bill, whatever the amount or date, unless the bill is bound " \
                               "to a merchant and the payment carries a different one. Needs an account; not for " \
                               "income. Use something distinctive, at least 3 characters."

  REFERENCE_ONLY_DESCRIPTION = "With a bank_reference set: match payments by that reference alone and ignore " \
                               "the bill's name and merchant. Default false; has no effect without a reference."

  # The write tools' cadence enum: the named presets, plus "custom" for an
  # every-N cadence described by interval_count and interval_unit.
  FREQUENCIES = (RecurringTransaction::FrequencyPreset::PRESETS + [ RecurringTransaction::FrequencyPreset::CUSTOM ]).freeze

  # interval_unit words and the rule frequency each one stores. The schedule
  # engine repeats by week, month or year only, so "day" is accepted for
  # whole weeks and stored as weeks.
  INTERVAL_UNITS = { "week" => "weekly", "month" => "monthly", "year" => "yearly" }.freeze
  CUSTOM_INTERVAL_UNITS = ([ "day" ] + INTERVAL_UNITS.keys).freeze
  DAYS_PER_WEEK = 7

  INTERVAL_COUNT_DESCRIPTION = "With frequency custom only, and then required: repeat every this many units, " \
                               "a whole number from 1 (3 with interval_unit week is every 3 weeks)."
  INTERVAL_UNIT_DESCRIPTION = "With frequency custom only, and then required. day counts only in whole weeks " \
                              "(21 days is stored as 3 weeks): bills repeat by week, month or year."

  # The tool caller does not enforce params_schema, so a string "true" from
  # a loose MCP client would otherwise compare unequal to true and silently
  # flip a paycheck into a bill. An explicit allowlist, not
  # ActiveModel::Type::Boolean, because that cast reads every unrecognized
  # string as true, and a financial write is the wrong place to guess.
  TRUTHY_INPUTS = [ true, "true", "t", "1", 1 ].freeze
  FALSY_INPUTS = [ false, "false", "f", "0", 0 ].freeze

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
      every_n = detection.key == RecurringTransaction::FrequencyPreset::INTERVAL

      {
        id: series.id,
        name: series.display_name,
        bill_type: series.bill_type,
        status: display_status(series),
        amount: series.amount_money.abs.format,
        currency: series.currency,
        # The tools' frequency enum is PRESETS plus custom; an every-N cadence
        # outside the presets reads as custom, with its interval beside it so
        # the cadence can be read back and passed to the write tools as is.
        # Other custom shapes (an nth weekday, say) carry no single interval.
        frequency: detection.key.presence_in(RecurringTransaction::FrequencyPreset::PRESETS) || "custom",
        interval_count: (detection.interval if every_n),
        interval_unit: (INTERVAL_UNITS.key(detection.interval_unit) if every_n),
        next_due_date: series.next_due_date&.iso8601,
        autopay: series.autopay,
        detected_automatically: !series.manual,
        category: series.category&.name,
        account: account_ref(series.account),
        destination_account: account_ref(series.destination_account),
        monthly_equivalent: series.monthly_equivalent_amount&.abs&.format,
        payment_url: series.payment_url,
        bank_reference: series.bank_reference,
        reference_only: series.reference_only?
      }.compact
    end

    def serialize_occurrence(occurrence)
      return nil if occurrence.nil?

      # Read once, derive locally: resolved_expected_amount is unmemoized and
      # can cost two queries per call under the `last` amount strategy.
      expected = occurrence.resolved_expected_amount
      paid = occurrence.confirmed_allocated

      # Nobody is paying a bill that isn't active, so its leftover reports the
      # pause, not a schedule state that calls it overdue.
      series = occurrence.recurring_transaction
      state = if occurrence.scheduled? && !series.active?
        display_status(series)
      else
        occurrence.derived_state.to_s
      end

      {
        due_on: occurrence.due_on.iso8601,
        effective_due_on: occurrence.effective_due_on.iso8601,
        state: state,
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

    def resolve_boolean(params, key)
      value = params[key]
      return [ false, nil ] if value.nil?

      normalized = value.is_a?(String) ? value.strip.downcase : value
      return [ true, nil ] if TRUTHY_INPUTS.include?(normalized)
      return [ false, nil ] if FALSY_INPUTS.include?(normalized)

      [ nil, {
        error: "#{key} must be true or false",
        hint: "Pass a JSON boolean, not #{value.inspect}."
      } ]
    end

    # YYYY-MM-DD only. Date.parse reads "3" as the 3rd of this month and
    # "next tuesday" as a date, and a schedule's anchor is the wrong place to
    # guess. nil when the value is absent or does not parse.
    def strict_date(value)
      Date.iso8601(value.to_s) if value.present?
    rescue Date::Error
      nil
    end

    # [[interval, rule frequency], nil] for frequency "custom", [nil, nil] for
    # any other cadence, or [nil, error]. interval_count and interval_unit
    # belong to "custom" alone: beside a named cadence they would be ignored,
    # and a financial write is the wrong place to guess which one was meant.
    def resolve_custom_interval(params, frequency)
      given = %w[interval_count interval_unit].select { |key| params[key].present? }

      unless frequency == RecurringTransaction::FrequencyPreset::CUSTOM
        return [ nil, nil ] if given.empty?

        return [ nil, {
          error: "#{given.to_sentence} only #{given.one? ? 'applies' : 'apply'} to frequency custom",
          hint: "Pass frequency \"custom\" with interval_count and interval_unit, or drop them for a named cadence."
        } ]
      end

      missing = %w[interval_count interval_unit] - given
      if missing.any?
        return [ nil, {
          error: "frequency custom needs #{missing.to_sentence}",
          hint: "Pass interval_count (a whole number from 1) and interval_unit (#{CUSTOM_INTERVAL_UNITS.join(', ')}), " \
                "e.g. 3 and week for every 3 weeks."
        } ]
      end

      count = strict_integer(params["interval_count"])
      if count.nil? || count < 1
        return [ nil, {
          error: "interval_count must be a whole number of at least 1",
          hint: "Pass an integer such as 3, not #{params["interval_count"].inspect}."
        } ]
      end

      unit = params["interval_unit"].to_s
      unless CUSTOM_INTERVAL_UNITS.include?(unit)
        return [ nil, {
          error: "#{unit.inspect} is not an interval unit this app recognizes",
          hint: "Use one of: #{CUSTOM_INTERVAL_UNITS.join(', ')}."
        } ]
      end

      if unit == "day"
        unless (count % DAYS_PER_WEEK).zero?
          return [ nil, {
            error: "Every #{count} days is not a cadence this app can schedule",
            hint: "Bills repeat by week, month or year, so a count of days must be whole weeks " \
                  "(a multiple of #{DAYS_PER_WEEK}). Ask the user which weekly or monthly cadence is closest."
          } ]
        end

        count /= DAYS_PER_WEEK
        unit = "week"
      end

      max = RecurringTransaction::FrequencyPreset::MAX_INTERVAL
      if count > max
        return [ nil, {
          error: "interval_count can be at most #{max} #{unit.pluralize}",
          hint: "Use a larger interval_unit for a cadence that long."
        } ]
      end

      [ [ count, INTERVAL_UNITS.fetch(unit) ], nil ]
    end

    # A typed count is parsed whole: to_i would read "2.5" as 2 and "3abc" as
    # 3. Base 10 because Integer alone reads "010" as octal.
    def strict_integer(value)
      return value if value.is_a?(Integer)

      Integer(value.to_s, 10, exception: false)
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
