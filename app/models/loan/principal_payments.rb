class Loan
  # Replays a loan's ledger into the principal and interest each payment
  # actually paid.
  #
  # Interest is charged once per scheduled period, on the principal the period
  # opened with, using the loan's own day-count convention. A payment therefore
  # reduces principal by only the part left after interest. This is the same
  # engine the schedule uses, so a borrower who pays the schedule matches it
  # row for row.
  #
  # Only a manual loan whose opening anchor is its real origination is
  # replayed. A provider-owned loan's anchor is a current balance dated into
  # the past, so charging interest on it would invent a history.
  class PrincipalPayments
    Change = Data.define(:principal_paid, :principal_added, :interest_paid) do
      def net
        principal_added - principal_paid
      end
    end

    # The replay walks scheduled dates and entry dates in one ordered stream.
    # `period_interest` is nil until the open period has been charged; a nil
    # amount is different from a genuine zero-rate charge.
    State = Struct.new(
      :principal,
      :carried_interest,
      :period_interest,
      :period_start,
      :period_principal,
      :payment_index,
      keyword_init: true
    )

    def self.for(loan, entries:)
      account = loan&.account
      return nil unless loan&.amortizable? && account&.manual?
      return nil unless account.has_opening_anchor? && account.opening_anchor_balance.to_d.positive?
      return nil unless loan.initial_balance.present? && loan.initial_balance.to_d.positive?
      return nil unless anchor_matches_origination?(loan, account)

      new(loan, entries: entries)
    end

    def self.anchor_matches_origination?(loan, account)
      return false unless account.opening_anchor_date == loan.origination_date

      precision = Money::Currency.new(account.currency).default_precision || 2
      account.opening_anchor_balance.to_d.round(precision) ==
        loan.original_balance.amount.round(precision)
    end
    private_class_method :anchor_matches_origination?

    def initialize(loan, entries:)
      @loan = loan
      @account = loan.account
      @entries = entries
      @changes = build_changes
    end

    def change_for(date)
      @changes[date]
    end

    def changes
      @changes
    end

    private
      attr_reader :loan, :account, :entries

      def build_changes
        return {} if schedule.nil?

        state = State.new(
          principal: opening_balance,
          carried_interest: BigDecimal("0"),
          period_interest: nil,
          period_start: anchor_date,
          period_principal: opening_balance,
          payment_index: 0
        )

        changes = {}

        timeline.each do |date|
          next if date < anchor_date

          advance_closed_periods(state, date)
          charge_period(state) if charge_period_for_date?(state, date)

          transactions = transactions_on(date)
          change = process_transactions(state, date, transactions) if transactions.any?

          if (valuation = valuation_on(date))
            apply_valuation(state, valuation)
            # A valuation-only day still needs an entry so callers can see the
            # reset. A payment on the same day keeps its own change: the
            # valuation resets the balance, but the payment still happened.
            changes[date] = change || zero_change
          elsif change
            changes[date] = change
          end

          close_period(state, date) if due_date?(state, date)
        end

        changes
      end

      # Close every scheduled period that ended before this date. A period
      # with no payment still accrues its charge; it is carried, not lost.
      def advance_closed_periods(state, date)
        while (payment = schedule.payments[state.payment_index]) && payment.date < date
          charge_period(state)
          close_period(state, payment.date)
        end
      end

      def charge_period_for_date?(state, date)
        return false unless state.period_interest.nil?
        return true if due_date?(state, date)
        # A payment between due dates pays interest already carried before it
        # pays the next period's charge.
        return false if state.carried_interest.positive?

        transactions_on(date).any?
      end

      def charge_period(state)
        payment = schedule.payments[state.payment_index]
        return if payment.nil? || payment.date <= state.period_start

        factor = AmortizationMath.accrual_factor(
          annual_percentage: rate_resolver.accrual_rate_for(state.period_start),
          period_start: state.period_start,
          period_end: payment.date,
          day_count_convention: day_count_convention
        )

        state.period_interest = (state.period_principal * factor).round(precision)
      end

      def close_period(state, date)
        payment = schedule.payments[state.payment_index]
        return unless payment && payment.date == date

        state.carried_interest += period_interest(state)
        state.period_interest = nil
        state.period_start = date
        state.period_principal = state.principal
        state.payment_index += 1
      end

      def process_transactions(state, date, transactions)
        linked, unlinked = transactions.partition { |entry| linked?(entry) }
        linked_positive, linked_negative = linked.partition { |entry| entry.amount.positive? }
        unlinked_positive, unlinked_negative = unlinked.partition { |entry| entry.amount.positive? }

        added = linked_positive.sum(BigDecimal("0"), &:amount).round(precision)
        state.principal += added

        apply_ledger_charge(state, date, unlinked_positive.sum(BigDecimal("0"), &:amount).round(precision))

        payment = instalment_for(state, date)
        principal_only, full_linked = linked_negative.partition { |entry| principal_only?(entry, payment) }

        principal_paid = BigDecimal("0")
        interest_paid = BigDecimal("0")

        principal_only.each do |entry|
          applied = [ (-entry.amount).round(precision), state.principal ].min
          state.principal -= applied
          principal_paid += applied

          # A principal-only transfer pays the instalment's interest as a
          # separate expense. Count it once; it never reduces principal again.
          separately_paid = principal_only_interest(state, date)
          next unless separately_paid.positive?

          if state.carried_interest.positive? && !due_date?(state, date)
            state.carried_interest -= separately_paid
          else
            state.period_interest = BigDecimal("0")
          end
          interest_paid += separately_paid
        end

        full_amount = (full_linked + unlinked_negative).sum(BigDecimal("0")) { |entry| -entry.amount }.round(precision)

        if full_amount.positive?
          paid_interest = [ full_amount, state.carried_interest + period_interest(state) ].min
          state.carried_interest, state.period_interest =
            allocate_interest(state.carried_interest, period_interest(state), paid_interest)

          remaining = full_amount - paid_interest
          remaining = remaining_after_premium(remaining, payment, full_amount, paid_interest)
          applied = [ remaining, state.principal ].min
          state.principal -= applied
          principal_paid += applied
          interest_paid += paid_interest
        end

        Change.new(
          principal_paid: principal_paid.round(precision),
          principal_added: added.round(precision),
          interest_paid: interest_paid.round(precision)
        )
      end

      # An unlinked positive line on a manual loan is the statement's charge
      # for the period. It replaces the engine's accrual, so the same interest
      # is not counted twice and a statement that charges a different figure
      # stays authoritative. A line that arrives after its due date belongs to
      # the charge already carried.
      def apply_ledger_charge(state, date, amount)
        return unless amount.positive?

        if state.carried_interest.positive? && !due_date?(state, date)
          state.carried_interest = amount
        else
          state.period_interest = amount
        end
      end

      def allocate_interest(carried, period, paid)
        from_carried = [ paid, carried ].min
        from_period = [ paid - from_carried, period ].min

        [ carried - from_carried, period - from_period ]
      end

      # The premium is charged alongside the instalment. When the payment
      # covers the instalment's principal, the interest actually paid and the
      # premium, the premium is not principal.
      def remaining_after_premium(remaining, payment, full_amount, paid_interest)
        return remaining if payment.nil?

        premium = premium_for(payment)
        return remaining unless premium.positive?

        covered = payment.principal.amount + paid_interest + premium
        return remaining if full_amount < covered

        [ remaining - premium, BigDecimal("0") ].max
      end

      def principal_only?(entry, payment)
        return false if payment.nil?

        same_amount?(-entry.amount, payment.principal.amount)
      end

      # A late principal-only transfer belongs to the period it missed; an
      # early one belongs to the period it is paying into.
      def instalment_for(state, date)
        return schedule.payments[state.payment_index] if due_date?(state, date)
        if state.carried_interest.positive? && state.payment_index.positive?
          return schedule.payments[state.payment_index - 1]
        end

        schedule.payments[state.payment_index] || schedule.payments.last
      end

      def principal_only_interest(state, date)
        return state.carried_interest if state.carried_interest.positive? && !due_date?(state, date)

        period_interest(state)
      end

      def apply_valuation(state, valuation)
        state.principal = valuation.amount.to_d.round(precision)
        state.carried_interest = BigDecimal("0")
        state.period_interest = nil
        state.period_start = valuation.date
        state.period_principal = state.principal

        # Periods whose due date is on or before the valuation are behind the
        # reset; the next period starts from the valuation.
        while (payment = schedule.payments[state.payment_index]) && payment.date <= valuation.date
          state.payment_index += 1
        end
      end

      def transactions_on(date)
        entries_by_date[date]&.select(&:transaction?) || []
      end

      def valuation_on(date)
        entries_by_date[date]&.find(&:valuation?)
      end

      def entries_by_date
        @entries_by_date ||= entries.group_by(&:date)
      end

      def timeline
        @timeline ||= begin
          entry_dates = entries.map(&:date)
          last_entry_date = entry_dates.max
          # Nothing after the last entry can change a balance, so future
          # instalments are not walked.
          due_dates = schedule.payments.map(&:date).select { |date| last_entry_date && date <= last_entry_date }

          (due_dates + entry_dates).uniq.sort
        end
      end

      def due_date?(state, date)
        schedule.payments[state.payment_index]&.date == date
      end

      def linked?(entry)
        linked_transaction_ids.include?(entry.entryable_id)
      end

      def linked_transaction_ids
        @linked_transaction_ids ||= begin
          ids = entries.select(&:transaction?).map(&:entryable_id)
          if ids.empty?
            Set.new
          else
            Transfer.where("inflow_transaction_id IN (?) OR outflow_transaction_id IN (?)", ids, ids)
              .pluck(:inflow_transaction_id, :outflow_transaction_id)
              .flatten
              .to_set
          end
        end
      end

      def rate_resolver
        @rate_resolver ||= Loan::RateResolver.for(loan)
      end

      def schedule
        @schedule ||= loan.amortization_schedule
      end

      def premium_for(payment)
        premium = loan.insurance&.premium_for(payment.number)
        premium ? premium.amount.amount : BigDecimal("0")
      end

      def period_interest(state)
        state.period_interest || BigDecimal("0")
      end

      def opening_balance
        @opening_balance ||= account.opening_anchor_balance.to_d.round(precision)
      end

      def anchor_date
        @anchor_date ||= account.opening_anchor_date
      end

      def day_count_convention
        @day_count_convention ||= (loan.day_count_convention.presence || Loan::DEFAULT_DAY_COUNT_CONVENTION).to_sym
      end

      def same_amount?(left, right)
        (BigDecimal(left.to_s) - BigDecimal(right.to_s)).abs <= BigDecimal("1") / (10 ** precision)
      end

      def precision
        @precision ||= Money::Currency.new(account.currency).default_precision || 2
      end

      def zero_change
        Change.new(
          principal_paid: BigDecimal("0"),
          principal_added: BigDecimal("0"),
          interest_paid: BigDecimal("0")
        )
      end
  end
end
