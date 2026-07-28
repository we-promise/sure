# Projects the family's combined cash (Depository) balance forward 30 days by
# layering known recurring transactions on top of a statistical daily-spend
# baseline, and warns when the projected balance dips below the threshold.
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
    entries = upcoming_recurring_entries
    recurring_by_date = entries.group_by(&:date)

    # The recurring bills are part of the monthly median too — subtract them so
    # they aren't counted twice when we spread the remainder across the horizon.
    median_monthly_expense = income_statement.median_expense(interval: "month").to_d
    return [] if median_monthly_expense <= 0 && entries.empty?

    recurring_expense_total = entries.sum { |e| [ e.amount.to_d, 0.to_d ].max }
    other_daily_spend = [ median_monthly_expense - recurring_expense_total, 0.to_d ].max / HORIZON_DAYS

    balance = starting_balance
    low_point = starting_balance
    low_date = Date.current

    (1..HORIZON_DAYS).each do |offset|
      date = Date.current + offset
      balance -= other_daily_spend
      recurring_by_date.fetch(date, []).each { |e| balance -= e.amount.to_d }

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
          projected_low_bucket: (round(low_point, 0).to_i / 250) * 250
        },
        period: Period.custom(start_date: Date.current, end_date: Date.current + HORIZON_DAYS),
        dedup_key: "cash_flow_warning:#{month_token}"
      )
    ]
  end

  private
    def cash_accounts
      family.accounts.visible.where(accountable_type: "Depository", currency: family.currency)
    end

    # Projected occurrences of known recurring transactions within the horizon.
    # Transfers are internal moves, and cross-currency amounts can't be applied
    # to a family-currency balance without a rate lookup, so both are skipped.
    def upcoming_recurring_entries
      family.recurring_transactions
        .expected_soon
        .where(destination_account_id: nil)
        .filter_map(&:projected_entry)
        .select { |e| e.currency == family.currency && e.date <= Date.current + HORIZON_DAYS }
    end
end
