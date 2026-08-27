class RecurringTransaction
  # Slices time by the family's declared income schedule and funds every open
  # obligation from the paycheck of the window it falls due in, so each period
  # reports what is due inside it, what it holds for a later bill that outgrows
  # its own paycheck, and what is safe once both are taken out.
  #
  # Only manually declared income defines paydays; detected inflows never do.
  class PaycheckPlanner
    # `remaining_total` is the whole obligation this share is a slice of,
    # pre-converted to the family currency so no view has to convert money.
    Item = Data.define(:occurrence, :share, :remaining_total, :due_in_period)

    Period = Data.define(
      :starts_on, :ends_on, :income, :income_sources, :items,
      :due_total, :reserved_total, :obligation_total, :remaining, :leading, :final,
      :cash_on_hand
    ) do
      # The window between today and the next payday: nothing arrives in it, so
      # what it needs must come from cash already in hand.
      def bridge?
        leading && !income.positive?
      end

      # A bridge window earns no income by construction, so measuring it the
      # way every other window is measured guarantees a shortfall the instant
      # any bill falls inside it. That is not a warning, it is a restatement of
      # having a bill before payday, and it fired for everyone who did.
      #
      # What actually decides whether that window is a problem is the cash
      # already in hand, which is what this always claimed to compare and never
      # did. When the balance cannot be established, cash_on_hand is nil and
      # nothing is claimed: an unknown balance is not evidence of a shortfall.
      def short?
        if bridge?
          # An unknown balance is not evidence of a shortfall.
          cash_on_hand.present? && obligation_total > cash_on_hand
        else
          remaining.negative?
        end
      end

      def shortfall
        return BigDecimal("0") unless short?

        bridge? ? obligation_total - cash_on_hand : -remaining
      end

      # What the cash still covers once the window's bills are met. nil when
      # the balance is unknown, so copy can stay quiet rather than guess.
      def cash_after_obligations
        return nil unless bridge? && cash_on_hand.present?

        cash_on_hand - obligation_total
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
      # A single boundary (every upcoming paycheck lands today) yields no
      # periods to spread anything across.
      return [] if periods.empty?

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
          final: period[:final],
          cash_on_hand: period[:leading] ? cash_on_hand : nil
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

      # Each obligation is funded by the paycheck of the window it falls due
      # in. Only what that paycheck cannot cover cascades backward into earlier
      # windows as reserves, nearest paycheck first, so a reserve always means
      # a bill outgrew one paycheck and never bookkeeping noise. Overflow no
      # earlier paycheck can absorb piles onto the earliest one, surfacing the
      # shortfall today instead of the week the bill lands.
      #
      # A reserve has to come out of a paycheck, so only periods that receive
      # income can carry one. The leading window is the gap before the next
      # payday and has no income by definition: it carries only what genuinely
      # falls due inside it, paid from cash already in hand.
      def apportion_bills(periods)
        available = periods.map { |period| period[:income] }

        # Chronological, so each window's own bills claim its paycheck before
        # any later window's overflow reaches back for the spare.
        occurrences = open_payable_occurrences(periods.last[:ends_on])
                        .sort_by { |occurrence| [ occurrence.due_on, occurrence.id ] }

        occurrences.each do |occurrence|
          remaining = to_family_currency(occurrence.remaining_amount_money)
          next unless remaining.positive?

          # A past-due open occurrence still needs paying; it lands whole in
          # the leading window, since every share of it is already owed.
          effective_due = [ occurrence.due_on, periods.first[:starts_on] ].max
          home = periods.index { |period| effective_due.between?(period[:starts_on], period[:ends_on]) }
          next if home.nil?

          funded = [ remaining, [ available[home], 0 ].max ].min
          uncovered = remaining - funded

          # Earlier paychecks, nearest first. The earliest takes whatever the
          # others could not and goes short, so the gap shows now rather than
          # the week the bill arrives.
          sources = (0...home).select { |index| periods[index][:income].positive? }.reverse

          sources.each do |index|
            break unless uncovered.positive?

            take = index == sources.last ? uncovered : [ uncovered, [ available[index], 0 ].max ].min
            next unless take.positive?

            available[index] -= take
            uncovered -= take
            periods[index][:items] << Item.new(
              occurrence: occurrence,
              share: take,
              remaining_total: remaining,
              due_in_period: false
            )
          end

          # With no earlier paycheck to lean on, the bill's own window carries
          # all of it, shortfall included.
          funded += uncovered if uncovered.positive?

          available[home] -= funded
          periods[home][:items] << Item.new(
            occurrence: occurrence,
            share: funded,
            remaining_total: remaining,
            due_in_period: true
          )
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
              .tap { |occurrences| preload_confirmed_sums(occurrences) }
      end

      # Cash a bill can actually be paid from before the next paycheck: the
      # family's own deposit accounts, minus the tax-advantaged ones nobody
      # spends rent out of. Credit cards share the `:cash` balance type but are
      # a liability, so they are not money on hand.
      #
      # nil, never zero, when there is nothing to read. Zero would assert the
      # user is broke and raise a shortfall on that basis; nil says the balance
      # is unknown and the window goes unjudged.
      def cash_on_hand
        return @cash_on_hand if defined?(@cash_on_hand)

        accounts = family.accounts.visible
                         .where(accountable_type: "Depository")
                         .merge(Account.accessible_by(user))

        excluded = family.tax_advantaged_account_ids
        accounts = accounts.where.not(id: excluded) if excluded.present?

        @cash_on_hand =
          if accounts.exists?
            # One unconvertible account must not shrink the balance silently: a
            # partial sum reads as "short" when the missing account might cover
            # everything. Unknown stays unknown.
            balances = accounts.map do |account|
              account.balance_money.exchange_to(family.currency).amount
            rescue Money::ConversionError
              @unconvertible_count += 1
              nil
            end

            balances.sum unless balances.include?(nil)
          end
      end

      # An unconvertible obligation is counted and reported, never folded in as
      # zero, which would inflate what the plan says is safe to spend.
      # remaining_amount aggregates confirmed allocations per occurrence, one
      # query each. Same grouped-sum-into-the-cache pattern the bills tools and
      # BudgetCategory#bills_reservation already use.
      def preload_confirmed_sums(occurrences)
        sums = RecurringAllocation.confirmed
                                  .where(recurring_occurrence_id: occurrences.map(&:id))
                                  .group(:recurring_occurrence_id)
                                  .sum(:allocated_amount)
        occurrences.each { |occurrence| occurrence.cached_confirmed_allocated = sums.fetch(occurrence.id, 0) }
      end

      def to_family_currency(money)
        money.exchange_to(family.currency).amount
      rescue Money::ConversionError
        @unconvertible_count += 1
        BigDecimal("0")
      end
  end
end
