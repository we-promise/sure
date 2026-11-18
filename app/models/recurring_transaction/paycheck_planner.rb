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

    # `beyond_horizon` and `unconvertible` say whether the window's bills are
    # all accounted for. Occurrences are only materialized up to a horizon, so a
    # window that reaches past it is missing the bills due after it, and a bill
    # with no exchange rate never makes it into the figures. Both default to
    # false so a period built by hand stays valid.
    Period = Data.define(
      :starts_on, :ends_on, :income, :income_sources, :items,
      :due_total, :reserved_total, :obligation_total, :remaining, :leading, :final,
      :cash_on_hand, :beyond_horizon, :unconvertible
    ) do
      def initialize(beyond_horizon: false, unconvertible: false, **attributes)
        super(beyond_horizon: beyond_horizon, unconvertible: unconvertible, **attributes)
      end

      # What the bills falling due inside this window cost in full. Not
      # `due_total`, which is only the share this window's own paycheck funds:
      # a bill that outgrows its paycheck leaves the rest as reserves in
      # earlier windows, but it still falls due here.
      def bills_total
        items_due.sum(&:remaining_total)
      end

      # Whether bills_total can be stated without leaving a bill out.
      def bills_total_known?
        !beyond_horizon && !unconvertible
      end

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

      # Chronological, because both render as a ledger keyed on the due date,
      # the snoozed one where a bill was snoozed. `items` itself stays ordered
      # by share, for weight-first callers.
      def items_due
        items.select(&:due_in_period).sort_by { |item| item.occurrence.effective_due_on }
      end

      def items_reserved
        items.reject(&:due_in_period).sort_by { |item| item.occurrence.effective_due_on }
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
    #
    # By default the plan covers `periods_limit` paychecks after the leading
    # window. With `through:` it covers every paycheck up to that date instead,
    # and closes the last one at the payday after it, derived from the income
    # schedule when no row for it is stored yet. Windows then also end at paydays
    # that are already settled, so a window never runs past a payday that has
    # arrived. `cash: false` skips the cash balance for callers that do not
    # show it.
    def plan(periods_limit: 3, through: nil, cash: true)
      incomes = upcoming_income_occurrences
      return nil if incomes.empty?

      boundaries = through ? boundaries_through(incomes, through) : period_boundaries(incomes, periods_limit)
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
          cash_on_hand: (cash && period[:leading]) ? cash_on_hand : nil,
          beyond_horizon: period[:ends_on] > Date.current + OccurrenceGenerator::HORIZON_DAYS,
          unconvertible: period[:unconvertible]
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
                # The snoozed date, the one the rows list a payday under, so a
                # snoozed payday opens the same window in every view.
                .where("#{RecurringOccurrence::EFFECTIVE_DUE_ON_SQL} >= ?", Date.current)
                .includes(:recurring_transaction)
                .order(Arel.sql(RecurringOccurrence::EFFECTIVE_DUE_ON_SQL), :id)
                .to_a
      end

      # Today up to the first paycheck is its own period, then one per paycheck.
      def period_boundaries(incomes, periods_limit)
        dates = incomes.map(&:effective_due_on).uniq.first(periods_limit + 1)
        boundaries = ([ Date.current ] + dates).uniq

        boundaries.first(periods_limit + 2)
      end

      # One period per open payday up to `through`, closed by the first payday
      # after the last of them. Settled paydays that fall between are boundaries
      # too; they open a window with no income of its own, which carries its
      # bills like any other and never reaches a view that does not ask for it.
      def boundaries_through(incomes, through)
        last_start = incomes.map(&:effective_due_on).select { |date| date <= through }.max
        return [] if last_start.nil?

        dates = window_dates(last_start)
        closing = dates.find { |date| date > last_start }

        ([ Date.current ] + dates.select { |date| date <= last_start } + [ closing ].compact).uniq
      end

      # Declared income only, like upcoming_income_occurrences, and the series
      # the successor paydays are derived from.
      def income_series
        @income_series ||=
          family.recurring_transactions
                .where(bill_type: "income", manual: true, status: "active")
                .accessible_by(user)
                .to_a
      end

      # Every date a window can end on: each income payday that has not been
      # skipped, settled ones included, plus the paydays that follow the last
      # one with a window.
      def window_dates(last_start)
        (stored_window_dates + derived_successor_dates(last_start)).uniq.sort
      end

      def stored_window_dates
        family.recurring_occurrences
              .where(recurring_transaction_id: income_series.map(&:id))
              .where.not(status: "skipped")
              .where("#{RecurringOccurrence::EFFECTIVE_DUE_ON_SQL} >= ?", Date.current)
              .distinct
              .pluck(Arel.sql(RecurringOccurrence::EFFECTIVE_DUE_ON_SQL))
              .map(&:to_date)
      end

      # Rows are only materialized up to a horizon, so the payday after the last
      # stored one may not exist yet. Derive each series' next payday from its
      # schedule, stepping past any the user skipped, so the last window is
      # still bounded.
      #
      # Compared by scheduled date (due_on), not effective date: a snooze moves
      # effective_due_on but the schedule still produces the original date. Only
      # rows after `last_start` can change the derived successor.
      def derived_successor_dates(last_start)
        rows = family.recurring_occurrences
                     .where(recurring_transaction_id: income_series.map(&:id))
                     .where("recurring_occurrences.due_on > ?", last_start)
                     .pluck(:recurring_transaction_id, :status, :due_on)
        skipped_dates = rows.select { |_, status, _| status == "skipped" }
                            .group_by(&:first)
                            .transform_values { |series_rows| series_rows.map { |_, _, due| due.to_date }.to_set }
        # A non-skipped row already sits on this scheduled date, so it is not derived.
        scheduled_dates = rows.reject { |_, status, _| status == "skipped" }
                              .map { |id, _, due| [ id, due.to_date ] }
                              .to_set

        income_series.filter_map do |series|
          skipped = skipped_dates.fetch(series.id, Set.new)
          taken = ->(date) { skipped.include?(date) || scheduled_dates.include?([ series.id, date ]) }
          # Schedules repeat before the income starts, so the successor cannot
          # fall before the series' anchor date. The occurrence generator
          # applies the same limit when it creates the stored rows.
          candidate = series.schedule.next_occurrence_after([ last_start, series.anchor_date&.prev_day ].compact.max)
          # Step past every taken date. Each step moves later and taken is finite.
          candidate = series.schedule.next_occurrence_after(candidate) while candidate && taken.call(candidate)
          candidate
        end
      end

      def build_periods(boundaries, incomes)
        boundaries.each_cons(2).map.with_index do |(starts_on, next_start), index|
          arrivals = incomes.select { |occurrence| occurrence.effective_due_on == starts_on }

          {
            starts_on: starts_on,
            ends_on: next_start - 1,
            income: arrivals.sum { |occurrence| to_family_currency(occurrence.resolved_expected_amount_money) },
            income_sources: arrivals.map { |occurrence| occurrence.recurring_transaction.display_name }.uniq,
            items: [],
            leading: index.zero?,
            final: false,
            unconvertible: false
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
                        .sort_by { |occurrence| [ occurrence.effective_due_on, occurrence.id ] }

        occurrences.each do |occurrence|
          # A snoozed bill falls due on the date it was snoozed to, the one the
          # overview's pay-period markers file it under. A past-due open
          # occurrence still needs paying; it lands whole in the leading
          # window, since every share of it is already owed.
          effective_due = [ occurrence.effective_due_on, periods.first[:starts_on] ].max
          home = periods.index { |period| effective_due.between?(period[:starts_on], period[:ends_on]) }
          next if home.nil?

          # A bill with no exchange rate is counted and left out, and its window
          # remembers it, so a total for that window is never stated as if the
          # bill were not there.
          remaining = begin
            occurrence.remaining_amount_money.exchange_to(family.currency).amount
          rescue Money::ConversionError
            @unconvertible_count += 1
            periods[home][:unconvertible] = true
            next
          end
          next unless remaining.positive?

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
              # The snoozed date, as apportion_bills reads it. A bill snoozed
              # past the plan is not one of its bills, not even one it failed
              # to convert.
              .where("#{RecurringOccurrence::EFFECTIVE_DUE_ON_SQL} <= ?", through)
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
