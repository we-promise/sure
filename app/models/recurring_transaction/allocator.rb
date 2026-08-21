class RecurringTransaction
  # The only supported write path for allocations: it holds the locks, freezes
  # the amount, and refreshes close state. A direct RecurringAllocation.create!
  # bypasses all three.
  #
  # Every write takes the occurrence row lock. Writes touching an entry also
  # take an advisory lock on the ENTRY, because two allocations of one
  # transaction against two different occurrences take different row locks,
  # never meet, and would both read the same stale capacity.
  #
  # Closing has two modes, and conflating them marks half-paid rent as settled:
  #
  #   * Actual-replaces-estimate: a SINGLE payment within the series' tolerance
  #     of the expected amount is the bill. Close paid.
  #   * Accumulation: multiple payments, or one below the band, close only when
  #     they sum to the full expected amount.
  class Allocator
    class OverAllocationError < StandardError; end
    class MissingRateError < StandardError; end

    # Postgres keeps single-key and two-key advisory locks in separate spaces,
    # so this cannot collide with the single-key family locks the jobs take.
    ENTRY_LOCK_NAMESPACE = 8311

    attr_reader :occurrence

    def initialize(occurrence)
      @occurrence = occurrence
    end

    # Records a payment: against an entry (full or custom amount) or as an
    # entry-less manual payment. Amounts are in the occurrence's currency;
    # a cross-currency entry converts at its own date's rate, or requires an
    # explicit amount when no rate exists.
    def allocate!(amount: nil, entry: nil, paid_on: nil, source: nil)
      occurrence.with_lock do
        with_entry_lock(entry) do
          allocated, source_amount, source_currency = resolve_amounts(amount, entry)
          guard_entry_capacity!(entry, source_amount) if entry
          freeze_expected_amount!

          allocation = occurrence.allocations.create!(
            entry: entry,
            allocated_amount: allocated,
            currency: occurrence.currency,
            source_amount: source_amount,
            source_currency: source_currency,
            state: "confirmed",
            source: source || (entry ? "user_confirmed" : "user_created"),
            paid_on: paid_on
          )

          learn_from_manual_attach!(allocation) if entry
          refresh_close_state!
          allocation
        end
      end
    end

    def unallocate!(allocation)
      occurrence.with_lock do
        with_entry_lock(allocation.entry) do
          allocation.destroy!
          refresh_close_state!
        end
      end
    end

    # The Matcher's write path: confirmed at the exact tier, suggested at the
    # high tier. Suggestions never move close state.
    def allocate_matched!(entry:, state:, confidence:, signals:)
      occurrence.with_lock do
        with_entry_lock(entry) do
          allocated, source_amount, source_currency = resolve_amounts(nil, entry)
          return nil unless allocated.positive?

          guard_entry_capacity!(entry, source_amount)
          freeze_expected_amount! if state == "confirmed"

          allocation = occurrence.allocations.create!(
            entry: entry,
            allocated_amount: allocated,
            currency: occurrence.currency,
            source_amount: source_amount,
            source_currency: source_currency,
            state: state,
            source: "auto_matched",
            match_confidence: confidence,
            match_signals: signals,
            paid_on: entry.date
          )

          refresh_close_state! if state == "confirmed"
          allocation
        end
      end
    end

    # Accepting a suggestion makes it a real payment.
    def confirm_suggestion!(allocation)
      occurrence.with_lock do
        with_entry_lock(allocation.entry) do
          freeze_expected_amount!
          allocation.update!(state: "confirmed", source: "user_confirmed")
          refresh_close_state!
        end
      end
    end

    # Records the (series, entry) pair so the matcher never proposes it again.
    def reject_suggestion!(allocation)
      occurrence.with_lock do
        with_entry_lock(allocation.entry) do
          if allocation.entry
            RecurringMatchRejection.find_or_create_by!(
              recurring_transaction: occurrence.recurring_transaction,
              entry: allocation.entry
            )
          end

          allocation.destroy!
        end
      end
    end

    # Settles the remainder with no transaction, as a user decision, so it
    # never auto-reopens. A backdated settlement carries its real payment date
    # into the history instead of defaulting to today.
    def mark_paid!(paid_on: nil)
      occurrence.with_lock do
        freeze_expected_amount!
        remaining = occurrence.remaining_amount

        if remaining.positive?
          occurrence.allocations.create!(
            allocated_amount: remaining,
            currency: occurrence.currency,
            state: "confirmed",
            source: "user_created",
            paid_on: paid_on
          )
        end

        occurrence.reload
        occurrence.close!("paid", source: "user") if occurrence.scheduled?
      end
    end

    # Re-derives the stored close state from the confirmed allocations:
    # closes an open occurrence that now qualifies, reopens an auto-closed one
    # that no longer does. User-closed occurrences never auto-reopen.
    def refresh_close_state!
      occurrence.reload

      if occurrence.scheduled?
        occurrence.close!("paid", source: "auto") if close_worthy?
      elsif occurrence.paid? && occurrence.closed_source == "auto" && !close_worthy?
        occurrence.reopen!
      end
    end

    private
      # Serializes every write touching this entry, whichever occurrence it
      # targets. Always taken inside the occurrence row lock, so the ordering is
      # occurrence then entry and no pair can deadlock.
      def with_entry_lock(entry)
        return yield if entry.nil?

        occurrence.class.connection.execute(
          ActiveRecord::Base.sanitize_sql_array(
            [ "SELECT pg_advisory_xact_lock(?::int, ?::int)", ENTRY_LOCK_NAMESPACE, entry_lock_id(entry) ]
          )
        )

        yield
      end

      def entry_lock_id(entry)
        Digest::MD5.hexdigest(entry.id.to_s).to_i(16) % (2**31)
      end

      # A confirmed payment pins the obligation it was made against. Open rows
      # otherwise inherit their amount from the series, which is correct until
      # money has moved: after that, re-resolving would re-target a payment the
      # user already made. Suggestions pin nothing.
      def freeze_expected_amount!
        return if occurrence.expected_amount.present?

        occurrence.update!(expected_amount: occurrence.resolved_expected_amount)
      end

      def close_worthy?
        expected = occurrence.resolved_expected_amount
        return false unless expected.positive?

        confirmed = occurrence.allocations.confirmed.to_a
        return false if confirmed.empty?

        total = confirmed.sum(&:allocated_amount)

        if confirmed.size == 1
          tolerance = expected * (occurrence.recurring_transaction.amount_tolerance_pct / BigDecimal("100"))
          return true if (confirmed.first.allocated_amount - expected).abs <= tolerance
        end

        total >= expected - RecurringOccurrence::CLOSE_EPSILON
      end

      def resolve_amounts(amount, entry)
        if entry.nil?
          raise ArgumentError, "an amount is required for a payment without a transaction" if amount.blank?

          return [ BigDecimal(amount.to_s), nil, nil ]
        end

        entry_total = entry.amount.abs

        if entry.currency == occurrence.currency
          allocated = if amount.present?
            BigDecimal(amount.to_s)
          else
            # Default: as much of the entry as this occurrence still needs --
            # or, when the occurrence is already covered, the entry's whole
            # unspoken-for amount (an explicit overpay attach). Either way it
            # is bounded by what the entry has left: an exhausted entry
            # allocates nothing, never the occurrence's outstanding balance.
            capacity = entry_capacity(entry, entry_total)
            remaining = occurrence.remaining_amount
            remaining.positive? ? [ capacity, remaining ].min : capacity
          end

          [ allocated, allocated, entry.currency ]
        else
          rate = ExchangeRate.find_or_fetch_rate(from: entry.currency, to: occurrence.currency, date: entry.date)&.rate

          if amount.present?
            allocated = BigDecimal(amount.to_s)
            source = rate ? (allocated / BigDecimal(rate.to_s)).round(4) : nil
            [ allocated, source, entry.currency ]
          elsif rate
            allocated = (entry_total * BigDecimal(rate.to_s)).round(4)
            [ allocated, entry_total, entry.currency ]
          else
            raise MissingRateError, "no exchange rate from #{entry.currency} to #{occurrence.currency}; enter an amount explicitly"
          end
        end
      end

      # How much of the entry is not yet spoken for, in the entry's currency.
      def entry_capacity(entry, entry_total)
        already = RecurringAllocation.where(entry: entry).sum(
          "COALESCE(source_amount, allocated_amount)"
        )

        [ entry_total - already, 0 ].max
      end

      # Two transparent things a manual attach can teach the matcher, both
      # stored in the series' user-visible matcher_hints:
      #
      #   * An alias: a name-keyed series attached to an entry it would not
      #     have recognized -- next time the matcher will.
      #   * A wider tolerance: when this SINGLE entry essentially is the bill
      #     and its amount sits outside the band, the band was too tight.
      #     Partial payments teach nothing -- a $537.50 installment against
      #     $2,150 rent is not evidence that rent varies. Being the only
      #     allocation does not make a payment the bill, so the test is
      #     whether it actually SETTLES the occurrence.
      def learn_from_manual_attach!(allocation)
        series = occurrence.recurring_transaction
        entry = allocation.entry
        hints = series.matcher_hints.deep_dup

        if series.merchant_id.blank? && series.name.present?
          known = ([ series.name ] + Array(hints["name_aliases"]))
                    .map { |name| Matcher.normalize_name(name) }

          unless known.include?(Matcher.normalize_name(entry.name))
            hints["name_aliases"] = (Array(hints["name_aliases"]) + [ entry.name ]).uniq
          end
        end

        expected = occurrence.resolved_expected_amount
        if expected.positive? && occurrence.allocations.confirmed.count == 1 && close_worthy?
          deviation_pct = (entry.amount.abs - expected).abs / expected * 100
          current = BigDecimal((hints["learned_tolerance_pct"] || 0).to_s)

          if deviation_pct > series.amount_tolerance_pct &&
             deviation_pct > current &&
             deviation_pct <= Matcher::MAX_LEARNED_TOLERANCE_PCT
            hints["learned_tolerance_pct"] = deviation_pct.round(1).to_f
          end
        end

        series.update!(matcher_hints: hints) if hints != series.matcher_hints
      end

      # One transaction can pay several occurrences, but never more than
      # itself. Compared in the ENTRY's currency via source_amount; a
      # cross-currency allocation whose source amount is unknowable (no rate)
      # is exempt, documented as such.
      def guard_entry_capacity!(entry, source_amount)
        return if source_amount.nil?

        capacity = entry_capacity(entry, entry.amount.abs)

        if source_amount > capacity + RecurringOccurrence::CLOSE_EPSILON
          raise OverAllocationError,
                "allocating #{source_amount} exceeds the transaction's remaining #{capacity} #{entry.currency}"
        end
      end
  end
end
