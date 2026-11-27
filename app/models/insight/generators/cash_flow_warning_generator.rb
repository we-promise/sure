# Projects the family's combined cash (Depository) balance forward 30 days by
# layering known recurring transactions on top of a statistical daily-spend
# baseline, and warns when the projected balance dips below the threshold.
# Bills subsystem: projects from materialized occurrences rather than one
# projected entry per series, so non-monthly bills are counted at their real
# frequency and partial payments shrink the projection.
class Insight::Generators::CashFlowWarningGenerator < Insight::Generator
  produces "cash_flow_warning"

  # Known limitation: family-currency units, tuned for dollar/euro-scale
  # currencies (¥500 ≈ $3 would make this threshold meaninglessly low).
  LOW_BALANCE_THRESHOLD = 500
  HORIZON_DAYS = 30

  def generate
    accounts = cash_accounts
    return [] if accounts.empty?

    starting_balance = accounts.sum(:balance).to_d
    flows = upcoming_recurring_flows(accounts)
    return [] if flows.empty? && median_monthly_expense <= 0

    # Money due out today may already be in the balance, so it is neither
    # subtracted nor taken out of the baseline; income due today and still
    # open has not arrived yet and counts from the start (as in
    # BillNotCoveredGenerator).
    today_flows, later_flows = flows.partition { |flow| flow.date == Date.current }
    flows_by_date = later_flows.group_by(&:date)

    # The recurring bills are part of the monthly median too — subtract them so
    # they aren't counted twice when we spread the remainder across the horizon.
    # Income is not part of the expense median, so it only adds on its date.
    # A bill snoozed out of the horizon will not be paid in it either, so it
    # leaves the baseline although it is not applied on any date. An overdue
    # bill snoozed into the horizon is applied on its new date but stays in the
    # baseline: the median does not hold it.
    recurring_expense_total = later_flows.select(&:in_median).sum { |flow| -flow.amount } + snoozed_out_expense_total
    other_daily_spend = [ median_monthly_expense - recurring_expense_total, 0.to_d ].max / HORIZON_DAYS

    balance = starting_balance + today_flows.sum { |flow| [ flow.amount, 0.to_d ].max }
    low_point = balance
    low_date = Date.current

    (1..HORIZON_DAYS).each do |offset|
      date = Date.current + offset
      balance -= other_daily_spend
      flows_by_date.fetch(date, []).each { |flow| balance += flow.amount }

      if balance < low_point
        low_point = balance
        low_date = date
      end
    end

    return [] if low_point >= LOW_BALANCE_THRESHOLD

    template_key = low_point.negative? ? "cash_flow_warning.negative" : "cash_flow_warning.low"

    [
      build_insight(
        insight_type: "cash_flow_warning",
        priority: low_point.negative? ? "high" : "medium",
        title: I18n.t("insights.titles.#{template_key}"),
        template_key: template_key,
        facts: {
          projected_low: format_money(low_point),
          projected_low_date: I18n.l(low_date),
          current_balance: format_money(starting_balance),
          horizon_days: HORIZON_DAYS
        },
        # Balances and projected dates drift with nearly every transaction, so
        # exact values here would read as a material change nightly — rewriting
        # the body and resurrecting dismissals. Only severity and a coarse
        # bucket of the low point are material; display values live in `facts`.
        metadata: {
          negative: low_point.negative?,
          projected_low_bucket: (round(low_point, 0).to_i / 250) * 250,
          accounts_digest: shared_accounts_digest
        },
        period: Period.custom(start_date: Date.current, end_date: Date.current + HORIZON_DAYS),
        dedup_key: "cash_flow_warning:#{month_token}"
      )
    ]
  end

  private
    def cash_accounts
      shared_accounts.visible.where(accountable_type: "Depository", currency: family.currency)
    end

    def median_monthly_expense
      @median_monthly_expense ||= income_statement.median_expense(interval: "month").to_d
    end

    # Signed flows of known recurring transactions within the horizon:
    # negative for bills, positive for income. Transfers are internal moves
    # (and loan or investment contributions are already in the expense
    # median), and cross-currency amounts can't be applied to a
    # family-currency balance without a rate lookup, so both are skipped.
    # Income only counts when it lands in one of the projected cash accounts;
    # a salary paid into a private account does not cover the shared balance.
    #
    # Deliberately NOT gated on family.recurring_transactions_disabled?, unlike
    # SubscriptionAuditGenerator. That generator's entire subject is "your
    # recurring transactions" — with detection off, there's nothing left to
    # report. Here, recurring transactions are one input refining a cash-flow
    # projection whose subject (will your balance dip low in the next 30 days)
    # stays meaningful either way. Disabling the setting only stops the
    # identification job from finding NEW recurring transactions
    # (IdentifyRecurringTransactionsJob) — it doesn't clear out ones already
    # identified, so this keeps using that last-known set rather than silently
    # degrading to the flatter median-only baseline.
    # in_median: the occurrence was originally due inside the horizon, so the
    # monthly expense median already holds it. An overdue bill snoozed into
    # the horizon belongs to an earlier month and is spent on top of it.
    Flow = Data.define(:date, :amount, :in_median)

    # Occurrence rows instead of one projected entry per series: a weekly
    # bill contributes every hit inside the horizon (the single-projection
    # version silently under-counted it fourfold), and partially paid
    # occurrences contribute only what actually remains. A snoozed occurrence
    # counts on the date it was snoozed to, including an overdue one snoozed
    # into the horizon; an overdue one that was not snoozed is left out, as the
    # balance cannot tell whether it was paid.
    def upcoming_recurring_flows(accounts)
      cash_account_ids = accounts.pluck(:id).to_set

      occurrences = load_occurrences(
        projected_occurrences.where("#{RecurringOccurrence::EFFECTIVE_DUE_ON_SQL} BETWEEN ? AND ?", Date.current, horizon_end)
      )

      occurrences.filter_map do |occurrence|
        series = occurrence.recurring_transaction
        remaining = occurrence.remaining_amount.to_d
        next unless remaining.positive?

        if series.amount.negative?
          next unless cash_account_ids.include?(series.account_id)

          Flow.new(date: occurrence.effective_due_on, amount: remaining, in_median: false)
        else
          Flow.new(date: occurrence.effective_due_on, amount: -remaining, in_median: occurrence.due_on >= Date.current)
        end
      end
    end

    # Bills originally due inside the horizon but snoozed past it: what
    # remains of them is part of the monthly expense median, yet nothing of it
    # will be spent in this window.
    def snoozed_out_expense_total
      occurrences = load_occurrences(
        projected_occurrences
          .where(due_on: Date.current..horizon_end)
          .where("#{RecurringOccurrence::EFFECTIVE_DUE_ON_SQL} > ?", horizon_end)
      )

      occurrences.sum do |occurrence|
        next 0.to_d if occurrence.recurring_transaction.amount.negative?

        [ occurrence.remaining_amount.to_d, 0.to_d ].max
      end
    end

    def projected_occurrences
      family.recurring_occurrences
        .open_status
        .joins(:recurring_transaction)
        .where(recurring_transactions: { status: :active, destination_account_id: nil })
        .merge(shared_recurring_transactions)
        .where(currency: family.currency)
    end

    # remaining_amount reads the confirmed-allocation sum, and this runs
    # nightly for every family: one grouped query instead of one SUM per
    # occurrence.
    def load_occurrences(scope)
      scope.includes(:recurring_transaction).to_a.tap do |occurrences|
        RecurringOccurrence.preload_confirmed_allocated(occurrences)
      end
    end

    def horizon_end
      Date.current + HORIZON_DAYS
    end
end
