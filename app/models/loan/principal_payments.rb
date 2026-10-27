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
  # A linked transfer is a full payment unless the loan opts in to
  # principal-only transfers. The opt-in covers the workflow from #1804: the
  # borrower transfers only principal and records the interest separately.
  #
  # Only a manual loan whose opening anchor is its real origination is
  # replayed. A provider-owned loan's anchor is a current balance dated into
  # the past, so charging interest on it would invent a history.
  class PrincipalPayments
    # A payment made a few days after the due date still belongs to that
    # period. Without this window, a weekend slip would charge the next period
    # on a principal the borrower had already repaid.
    PAYMENT_GRACE_DAYS = 5

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
      @premium_remaining = {}
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
      # A period already charged by an early payment is not charged again.
      def advance_closed_periods(state, date)
        while (payment = schedule.payments[state.payment_index]) && payment.date < date
          charge_period(state) if state.period_interest.nil?
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

        if state.period_principal <= 0
          state.period_interest = BigDecimal("0")
          return
        end

        factor = AmortizationMath.accrual_factor(
          annual_percentage: rate_resolver.accrual_rate_for(state.period_start),
          period_start: state.period_start,
          period_end: payment.date,
          day_count_convention: day_count_convention,
          full_period: scheduled_period_start?(state.period_start)
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

        added = transactions.sum(BigDecimal("0")) do |entry|
          entry.amount.positive? ? entry.amount : BigDecimal("0")
        end.round(precision)
        state.principal += added

        payment = instalment_for(state, date)
        principal_paid = BigDecimal("0")
        interest_paid = BigDecimal("0")

        linked_negative = linked.select { |entry| entry.amount.negative? }
        unlinked_negative = unlinked.select { |entry| entry.amount.negative? }

        principal_only, full_linked = if loan.principal_only_transfers?
          [ linked_negative, [] ]
        else
          [ [], linked_negative ]
        end

        principal_only.each do |entry|
          # No cap: an overpayment beyond the remaining principal leaves a
          # credit instead of being dropped.
          applied = (-entry.amount).round(precision)
          state.principal -= applied
          principal_paid += applied
          apply_grace_principal(state, date, applied)

          # The borrower records the instalment's interest separately. Count
          # it once; it never reduces principal again.
          interest_paid += principal_only_interest(state)
        end

        full_amount = (full_linked + unlinked_negative).sum(BigDecimal("0")) { |entry| -entry.amount }.round(precision)

        if full_amount.positive?
          paid_interest = apply_interest(state, full_amount)

          remaining = full_amount - paid_interest
          remaining = apply_premium(remaining, payment)
          # No cap: an overpayment beyond the remaining principal leaves a
          # credit instead of being dropped.
          applied = remaining
          state.principal -= applied
          principal_paid += applied
          apply_grace_principal(state, date, applied)
          interest_paid += paid_interest
        end

        Change.new(
          principal_paid: principal_paid.round(precision),
          principal_added: added.round(precision),
          interest_paid: interest_paid.round(precision)
        )
      end

      # A payment a few days after the due date still reduces the principal
      # the new period charges interest on. Beyond the window, the period keeps
      # the principal it opened with.
      def apply_grace_principal(state, date, applied)
        return unless applied.positive?
        return unless scheduled_period_start?(state.period_start)

        days = (date - state.period_start).to_i
        return unless days.positive? && days <= PAYMENT_GRACE_DAYS

        state.period_principal -= applied
      end

      # Apply a payment to carried interest first, then to the open period's
      # charge. A deferred period stays nil: deferred is not the same as a
      # genuine zero-rate charge.
      def apply_interest(state, amount)
        from_carried = [ amount, state.carried_interest ].min
        state.carried_interest -= from_carried

        from_period = BigDecimal("0")
        unless state.period_interest.nil?
          from_period = [ amount - from_carried, state.period_interest ].min
          state.period_interest -= from_period
        end

        from_carried + from_period
      end

      # The premium is charged alongside the instalment and is senior to
      # principal. Track its remaining amount per instalment so a payment in
      # two halves does not charge it twice and an underpayment cannot turn it
      # into principal.
      def apply_premium(remaining, payment)
        return remaining if payment.nil?

        due = premium_remaining(payment)
        return remaining unless due.positive?

        paid = [ remaining, due ].min
        @premium_remaining[payment.number] = due - paid
        remaining - paid
      end

      def premium_remaining(payment)
        @premium_remaining[payment.number] ||= premium_for(payment)
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

      def principal_only_interest(state)
        paid = state.carried_interest
        state.carried_interest = BigDecimal("0")

        if state.period_interest&.positive?
          paid += state.period_interest
          state.period_interest = BigDecimal("0")
        end

        paid
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

      # A period opened on a scheduled date is a full period for the day-count
      # convention. A period opened by a mid-period valuation is a stub.
      def scheduled_period_start?(date)
        scheduled_dates.include?(date)
      end

      def scheduled_dates
        @scheduled_dates ||= (schedule.payments.map(&:date) << anchor_date).to_set
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
        return BigDecimal("0") if payment.nil?

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
