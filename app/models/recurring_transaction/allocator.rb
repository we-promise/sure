class RecurringTransaction
  # Writes allocations against an occurrence and keeps its close state honest.
  # All writes take the occurrence row lock, so a user clicking and a
  # background job reconciling cannot race each other into a double payment.
  #
  # Closing has two deliberately different modes (they answer different
  # questions and conflating them marks half-paid rent as settled):
  #
  #   * Actual-replaces-estimate: a SINGLE payment landing within the series'
  #     tolerance of the expected amount IS the bill -- the expectation was an
  #     estimate and the charge is the actual (Comcast expected ~$119.99,
  #     charged $121.74). Close paid.
  #   * Accumulation: multiple payments (or a single one below the band) close
  #     only when they sum to the full expected amount, give or take a cent.
  #     $1,850 allocated against $2,000 rent stays partially paid, always.
  class Allocator
    class OverAllocationError < StandardError; end
    class MissingRateError < StandardError; end

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
        allocated, source_amount, source_currency = resolve_amounts(amount, entry)
        guard_entry_capacity!(entry, source_amount) if entry

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

        refresh_close_state!
        allocation
      end
    end

    def unallocate!(allocation)
      occurrence.with_lock do
        allocation.destroy!
        refresh_close_state!
      end
    end

    # Settles the remainder without a transaction -- the keystone manual-first
    # action. Closes as a USER decision, so it never auto-reopens.
    def mark_paid!
      occurrence.with_lock do
        remaining = occurrence.remaining_amount

        if remaining.positive?
          occurrence.allocations.create!(
            allocated_amount: remaining,
            currency: occurrence.currency,
            state: "confirmed",
            source: "user_created"
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
            # unspoken-for amount (an explicit overpay attach).
            capacity = entry_capacity(entry, entry_total)
            [ capacity, occurrence.remaining_amount ].select(&:positive?).min || capacity
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
