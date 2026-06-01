# Projects a family's cash balance 30 days forward using two layers:
#   1. Deterministic: RecurringTransaction records (known scheduled outflows)
#   2. Statistical: daily baseline from median monthly expense divided by 30
# Surfaces an insight if the projected balance falls below WARNING_THRESHOLD.
class Insight::Generators::CashFlowWarningGenerator < Insight::Generator
  WARNING_THRESHOLD = 500
  PROJECTION_DAYS   = 30

  def generate
    cash_accounts = family.accounts.visible.assets.where(accountable_type: "Depository")
    return [] if cash_accounts.empty?

    current_cash = cash_accounts.sum(:balance).to_f

    projected, events = project_balance(current_cash)
    low_date, low_balance = projected.min_by { |_, bal| bal }

    return [] if low_balance.nil? || low_balance > WARNING_THRESHOLD

    upcoming_outflows = events.select { |e| e[:type] == :outflow }.sum { |e| e[:amount] }

    metadata = {
      "projected_low_date"    => low_date.iso8601,
      "projected_low_balance" => low_balance.round(2),
      "current_balance"       => current_cash.round(2),
      "upcoming_outflows"     => upcoming_outflows.round(2),
      "account_count"         => cash_accounts.count
    }

    body = generate_body(
      "Based on your recurring bills and spending patterns, your cash balance may drop to " \
      "#{currency_symbol}#{low_balance.round(2)} around #{low_date.strftime("%B %-d")}. " \
      "You have #{currency_symbol}#{current_cash.round(2)} now and approximately " \
      "#{currency_symbol}#{upcoming_outflows.round(2)} in scheduled outflows over the next 30 days."
    )

    [
      GeneratedInsight.new(
        insight_type: "cash_flow_warning",
        priority:     low_balance < 0 ? "high" : "medium",
        title:        I18n.t("insights.cash_flow_warning.title",
                             date: low_date.strftime("%B %-d")),
        body:         body,
        metadata:     metadata,
        currency:     family.currency,
        period_start: Date.current,
        period_end:   PROJECTION_DAYS.days.from_now.to_date,
        dedup_key:    "cash_flow_warning:#{Date.current.strftime("%Y-%m")}"
      )
    ]
  end

  private
    # Returns [{Date => Float}, Array<event_hash>]
    def project_balance(current_cash)
      events = build_recurring_events
      daily_baseline = compute_daily_baseline

      balance = current_cash
      balance_by_date = {}

      (1..PROJECTION_DAYS).each do |day_offset|
        date = Date.current + day_offset

        events.each do |event|
          next unless event[:date] == date
          if event[:type] == :inflow
            balance += event[:amount]
          else
            balance -= event[:amount]
          end
        end

        balance -= daily_baseline
        balance_by_date[date] = balance
      end

      [ balance_by_date, events ]
    end

    def build_recurring_events
      family.recurring_transactions.active
        .where("next_expected_date <= ?", PROJECTION_DAYS.days.from_now.to_date)
        .where("next_expected_date > ?", Date.current)
        .includes(:merchant)
        .filter_map do |rt|
          display_amount = (rt.expected_amount_avg || rt.amount).to_f.abs
          {
            date:   rt.next_expected_date,
            amount: display_amount,
            type:   rt.amount.to_f > 0 ? :outflow : :inflow,
            label:  rt.merchant&.name || rt.name
          }
        end
    end

    def compute_daily_baseline
      median = family.income_statement.median_expense(interval: "month").to_f
      [ (median / 30.0).round(2), 0 ].max
    end
end
