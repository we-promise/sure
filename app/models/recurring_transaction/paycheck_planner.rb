class RecurringTransaction
  # Slices time by the family's DECLARED income schedule and apportions every
  # open obligation across the paychecks before its due date. The pay period,
  # not the calendar month, is the unit people paid weekly or biweekly
  # actually live in -- and declaration (an income series, like any bill) is
  # what makes this work for variable earners that paycheck-detection
  # schemes lock out.
  #
  # Apportioning is the installment answer without installment schema: rent
  # of $2,150 due the 29th, with four paychecks before it, shows ~$537.50 of
  # set-aside per paycheck. A bill due within one period lands whole.
  #
  # Every period reports the same three quantities, because those are the
  # three the page is built to say: what is DUE inside the window, what is
  # RESERVED out of it for something landing later, and what is SAFE once
  # both are taken out. `obligation_total` is the first two added together
  # and exists only so callers need not add them.
  class PaycheckPlanner
    # `remaining_total` is the whole obligation this share is a slice of,
    # already converted to the family currency. Carrying it here is what lets
    # a caller say "$134.38 toward the $537.50 due Sep 2" without converting
    # money inside a view, and what makes "which bill is making me short"
    # answer with the obligation rather than with the slice.
    Item = Data.define(:occurrence, :share, :remaining_total, :due_in_period)

    Period = Data.define(
      :starts_on, :ends_on, :income, :income_sources, :items,
      :due_total, :reserved_total, :obligation_total, :remaining, :leading, :final
    ) do
      # The window between today and the next payday. No income arrives in
      # it, so whatever it needs has to come out of cash already in hand --
      # which is a different question from "how much of this paycheck is
      # spare", and has to be asked differently.
      def bridge?
        leading && !income.positive?
      end

      def short?
        remaining.negative?
      end

      # How far short, as a positive figure to put in a sentence.
      def shortfall
        remaining.negative? ? -remaining : 0
      end

      # Both lists read chronologically. They are rendered as a ledger with the
      # date in a fixed left column, and a date column that does not descend in
      # order is worse than no date column at all. `items` stays ordered by
      # share, which is what largest_obligation and any weight-first caller
      # want.
      def items_due
        items.select(&:due_in_period).sort_by { |item| item.occurrence.due_on }
      end

      def items_reserved
        items.reject(&:due_in_period).sort_by { |item| item.occurrence.due_on }
      end

      # The obligation doing the most damage, measured by what it actually
      # costs. The slice this period happens to carry is an artifact of how
      # the plan spread it: "Watson Property, $537.50" answers "what is
      # making me short", and "$268.75" does not.
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

    # Every declared income series' next arrival, keyed by series id.
    #
    # The page used to read `next_expected_date` for this, the stored column
    # the Bills work already found unreliable, and which for income has no
    # useful reading once it is in the past: a paycheck that did not turn up
    # is not overdue, it is simply not the next one. Reading occurrences here
    # is also what makes the income list and the plan agree, since the plan
    # has always read occurrences.
    def next_income_by_series
      upcoming_income_occurrences.each_with_object({}) do |occurrence, index|
        index[occurrence.recurring_transaction_id] ||= occurrence
      end
    end

    private
      # Only income the user DECLARED (the "This is income" checkbox, or
      # marking a real paycheck transaction as recurring) defines paydays.
      # Auto-detected inflows never do: sign alone proves nothing -- a
      # recurring one-cent balance transfer is "income" by sign and would
      # slice time into nonsense periods.
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

      # Today up to the first paycheck is its own period ("until your next
      # paycheck": whatever is due there rides on cash already in hand), then
      # one period per paycheck.
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

      # Each open obligation spreads its REMAINING amount evenly across every
      # period from now through the one containing its due date; the last
      # share absorbs rounding so the sum is exact.
      def apportion_bills(periods)
        horizon_end = periods.last[:ends_on]

        open_payable_occurrences(horizon_end).each do |occurrence|
          eligible = periods.select { |period| period[:starts_on] <= occurrence.due_on }
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
        # Scoped to the family: the outer query is family-scoped anyway, but an
        # unbounded subquery over every account in the installation is a table
        # scan that grows with other people's data.
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

      # An obligation with no rate into the family currency is counted and
      # reported, never folded in as zero. Folding it in would quietly inflate
      # what the plan says is left to spend, which is the one number this view
      # exists to get right.
      def to_family_currency(money)
        money.exchange_to(family.currency).amount
      rescue Money::ConversionError
        @unconvertible_count += 1
        BigDecimal("0")
      end
  end
end
