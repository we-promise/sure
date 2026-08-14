class RecurringTransaction
  # Slices time by the family's declared income schedule and spreads every open
  # obligation across the paychecks that fall before it is due, so each period
  # reports what is due inside it, what is reserved out of it for a later bill,
  # and what is safe once both are taken out.
  #
  # Only manually declared income defines paydays; detected inflows never do.
  class PaycheckPlanner
    # `remaining_total` is the whole obligation this share is a slice of,
    # pre-converted to the family currency so no view has to convert money.
    Item = Data.define(:occurrence, :share, :remaining_total, :due_in_period)

    Period = Data.define(
      :starts_on, :ends_on, :income, :income_sources, :items,
      :due_total, :reserved_total, :obligation_total, :remaining, :leading, :final
    ) do
      # The window between today and the next payday: nothing arrives in it, so
      # what it needs must come from cash already in hand.
      def bridge?
        leading && !income.positive?
      end

      def short?
        remaining.negative?
      end

      def shortfall
        remaining.negative? ? -remaining : 0
      end

      # Chronological, because both render as a ledger keyed on the due date.
      # `items` itself stays ordered by share, for weight-first callers.
      def items_due
        items.select(&:due_in_period).sort_by { |item| item.occurrence.due_on }
      end

      def items_reserved
        items.reject(&:due_in_period).sort_by { |item| item.occurrence.due_on }
      end

      # By what the bill actually costs, not by the slice this period carries.
      def largest_obligation
        items.max_by(&:remaining_total)
      end
    end

    attr_reader :family, :user, :unconvertible_count

    def initialize(family, user:)
      @family = family
      @user = user
      @unconvertible_count = 0
    end

    # nil when no income schedule is declared (the view prompts for one).
    def plan(periods_limit: 3)
      incomes = upcoming_income_occurrences
      return nil if incomes.empty?

      boundaries = period_boundaries(incomes, periods_limit)
      periods = build_periods(boundaries, incomes)
      apportion_bills(periods)

      periods.map do |period|
        due_total = period[:items].sum { |item| item.due_in_period ? item.share : 0 }
        reserved_total = period[:items].sum { |item| item.due_in_period ? 0 : item.share }
        obligation_total = due_total + reserved_total

        Period.new(
          starts_on: period[:starts_on],
          ends_on: period[:ends_on],
          income: period[:income],
          income_sources: period[:income_sources],
          items: period[:items].sort_by { |item| -item.share },
          due_total: due_total,
          reserved_total: reserved_total,
          obligation_total: obligation_total,
          remaining: period[:income] - obligation_total,
          leading: period[:leading],
          final: period[:final]
        )
      end
    end

    # Every declared income series' next arrival, keyed by series id. Read from
    # occurrences, never from `next_expected_date`: a paycheck that did not turn
    # up is not overdue, it is simply not the next one.
    def next_income_by_series
      upcoming_income_occurrences.each_with_object({}) do |occurrence, index|
        index[occurrence.recurring_transaction_id] ||= occurrence
      end
    end

    private
      # Declared income only. Sign alone proves nothing: a recurring one-cent
      # balance transfer is income by sign and a payday by nothing.
      def upcoming_income_occurrences
        @upcoming_income_occurrences ||=
          family.recurring_occurrences
                .open_status
                .joins(:recurring_transaction)
                .where(recurring_transactions: { status: :active, bill_type: :income, manual: true })
                .merge(RecurringTransaction.accessible_by(user))
                .where("recurring_occurrences.due_on >= ?", Date.current)
                .includes(:recurring_transaction)
                .order(:due_on)
                .to_a
      end

      # Today up to the first paycheck is its own period, then one per paycheck.
      def period_boundaries(incomes, periods_limit)
        dates = incomes.map(&:due_on).uniq.first(periods_limit + 1)
        boundaries = ([ Date.current ] + dates).uniq

        boundaries.first(periods_limit + 2)
      end

      def build_periods(boundaries, incomes)
        boundaries.each_cons(2).map.with_index do |(starts_on, next_start), index|
          arrivals = incomes.select { |occurrence| occurrence.due_on == starts_on }

          {
            starts_on: starts_on,
            ends_on: next_start - 1,
            income: arrivals.sum { |occurrence| to_family_currency(occurrence.resolved_expected_amount_money) },
            income_sources: arrivals.map { |occurrence| occurrence.recurring_transaction.display_name }.uniq,
            items: [],
            leading: index.zero?,
            final: false
          }
        end.tap { |periods| periods.last[:final] = true if periods.any? }
      end

      # Each obligation spreads its remaining amount evenly across every period
      # up to the one it falls due in; the last share absorbs rounding.
      #
      # A reserve has to come out of a paycheck, so only periods that receive
      # income can carry one. The leading window is the gap before the next
      # payday and has no income by definition: charging it a share of a bill
      # due after that payday would report it as short by money it was never
      # going to see. It carries only what genuinely falls due inside it.
      def apportion_bills(periods)
        horizon_end = periods.last[:ends_on]

        open_payable_occurrences(horizon_end).each do |occurrence|
          eligible = periods.select do |period|
            next false unless period[:starts_on] <= occurrence.due_on

            period[:income].positive? || occurrence.due_on.between?(period[:starts_on], period[:ends_on])
          end
          next if eligible.empty?

          remaining = to_family_currency(occurrence.remaining_amount_money)
          next unless remaining.positive?

          base_share = (remaining / eligible.size).round(2)

          eligible.each_with_index do |period, index|
            share = index == eligible.size - 1 ? remaining - base_share * (eligible.size - 1) : base_share
            period[:items] << Item.new(
              occurrence: occurrence,
              share: share,
              remaining_total: remaining,
              due_in_period: occurrence.due_on.between?(period[:starts_on], period[:ends_on])
            )
          end
        end
      end

      def open_payable_occurrences(through)
        # Family-scoped: an unbounded subquery here scans every account in the
        # installation.
        debt_accounts = Account.where(family_id: family.id, accountable_type: %w[CreditCard Loan]).select(:id)

        family.recurring_occurrences
              .open_status
              .joins(:recurring_transaction)
              .where(recurring_transactions: { status: :active })
              .where("recurring_transactions.amount > 0")
              .merge(
                RecurringTransaction.where(destination_account_id: nil)
                                    .or(RecurringTransaction.where(destination_account_id: debt_accounts))
              )
              .merge(RecurringTransaction.accessible_by(user))
              .where("recurring_occurrences.due_on <= ?", through)
              .includes(recurring_transaction: :merchant)
              .to_a
      end

      # An unconvertible obligation is counted and reported, never folded in as
      # zero, which would inflate what the plan says is safe to spend.
      def to_family_currency(money)
        money.exchange_to(family.currency).amount
      rescue Money::ConversionError
        @unconvertible_count += 1
        BigDecimal("0")
      end
  end
end
