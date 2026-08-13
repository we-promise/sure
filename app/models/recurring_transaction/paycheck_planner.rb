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
  class PaycheckPlanner
    Item = Data.define(:occurrence, :share, :due_in_period)
    Period = Data.define(:starts_on, :ends_on, :income, :items, :obligation_total, :remaining, :final)

    attr_reader :family, :user

    def initialize(family, user:)
      @family = family
      @user = user
    end

    # nil when no income schedule is declared (the view prompts for one).
    def plan(periods_limit: 3)
      incomes = upcoming_income_occurrences
      return nil if incomes.empty?

      boundaries = period_boundaries(incomes, periods_limit)
      periods = build_periods(boundaries, incomes)
      apportion_bills(periods)

      periods.map do |period|
        obligation_total = period[:items].sum(&:share)

        Period.new(
          starts_on: period[:starts_on],
          ends_on: period[:ends_on],
          income: period[:income],
          items: period[:items].sort_by { |item| -item.share },
          obligation_total: obligation_total,
          remaining: period[:income] - obligation_total,
          final: period[:final]
        )
      end
    end

    private
      # Only income the user DECLARED (the "This is income" checkbox, or
      # marking a real paycheck transaction as recurring) defines paydays.
      # Auto-detected inflows never do: sign alone proves nothing -- a
      # recurring one-cent balance transfer is "income" by sign and would
      # slice time into nonsense periods.
      def upcoming_income_occurrences
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

      # Today up to the first paycheck is its own period ("before your next
      # paycheck": whatever is due there rides on cash already in hand), then
      # one period per paycheck.
      def period_boundaries(incomes, periods_limit)
        dates = incomes.map(&:due_on).uniq.first(periods_limit + 1)
        boundaries = ([ Date.current ] + dates).uniq

        boundaries.first(periods_limit + 2)
      end

      def build_periods(boundaries, incomes)
        boundaries.each_cons(2).map do |starts_on, next_start|
          {
            starts_on: starts_on,
            ends_on: next_start - 1,
            income: income_on(incomes, starts_on),
            items: [],
            final: false
          }
        end.tap { |periods| periods.last[:final] = true if periods.any? }
      end

      def income_on(incomes, date)
        incomes.select { |occurrence| occurrence.due_on == date }
               .sum { |occurrence| to_family_currency(occurrence.resolved_expected_amount_money) }
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
              due_in_period: occurrence.due_on.between?(period[:starts_on], period[:ends_on])
            )
          end
        end
      end

      def open_payable_occurrences(through)
        debt_accounts = Account.where(accountable_type: %w[CreditCard Loan]).select(:id)

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

      def to_family_currency(money)
        money.exchange_to(family.currency).amount
      rescue Money::ConversionError
        BigDecimal("0")
      end
  end
end
