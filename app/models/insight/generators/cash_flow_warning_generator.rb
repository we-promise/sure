class Insight::Generators::CashFlowWarningGenerator < Insight::Generator
  PROJECTION_DAYS = 30
  WARNING_THRESHOLD = 500

  def generate
    @cash_account_ids = cash_account_ids
    starting_balance = cash_balance
    return [] if starting_balance.nil?

    scheduled = scheduled_movements
    # The median-expense baseline already includes recurring bills, so we
    # subtract the projected recurring outflow to get a non-recurring/
    # discretionary daily floor — otherwise scheduled[date] subtracts the
    # same dollars a second time.
    monthly_baseline = family.income_statement.median_expense(interval: "month").to_f
    scheduled_outflow_total = scheduled.values.sum { |amount| [ amount, 0 ].max.to_f }
    recurring_daily = scheduled_outflow_total / PROJECTION_DAYS
    daily_baseline = [ (monthly_baseline / 30.0) - recurring_daily, 0 ].max

    balance = starting_balance
    low_point = starting_balance
    low_date = Date.current

    (1..PROJECTION_DAYS).each do |offset|
      date = Date.current + offset.days
      balance -= daily_baseline
      balance -= scheduled[date].to_f

      if balance < low_point
        low_point = balance
        low_date = date
      end
    end

    return [] if low_point >= WARNING_THRESHOLD

    priority = low_point.negative? ? "high" : "medium"
    metadata = {
      "starting_balance" => starting_balance.round(2),
      "projected_low" => low_point.round(2),
      "projected_low_date" => low_date.iso8601,
      "daily_baseline" => daily_baseline.round(2)
    }

    fallback = if low_point.negative?
      "Your cash balance is projected to go negative (#{format_money(low_point)}) around #{low_date.strftime('%b %-d')} " \
      "based on your usual spending and upcoming recurring payments."
    else
      "Your cash balance is projected to drop to about #{format_money(low_point)} around #{low_date.strftime('%b %-d')} " \
      "based on your usual spending and upcoming recurring payments."
    end

    body = generate_body(
      facts: {
        signal: "cash_flow_warning",
        starting_balance: format_money(starting_balance),
        projected_low: format_money(low_point),
        projected_low_date: low_date.strftime("%B %-d"),
        threshold: format_money(WARNING_THRESHOLD)
      },
      fallback: fallback
    )

    [
      GeneratedInsight.new(
        insight_type: "cash_flow_warning",
        priority: priority,
        title: "Low cash projected in the next #{PROJECTION_DAYS} days",
        body: body,
        metadata: metadata,
        currency: currency,
        period_start: Date.current,
        period_end: Date.current + PROJECTION_DAYS.days,
        dedup_key: "cash_flow_warning:#{Date.current.strftime('%Y-%m-%d')}"
      )
    ]
  end

  private
    def cash_account_ids
      family.accounts.visible.where(accountable_type: "Depository").pluck(:id).to_set
    end

    def cash_balance
      accounts = family.accounts.visible.where(accountable_type: "Depository")
      return nil if accounts.none?

      accounts.sum do |account|
        convert_to_family_currency(account.balance, account.currency)
      end
    end

    # A transfer where both endpoints are cash accounts already counted in
    # the starting balance nets to zero on the family's overall cash position;
    # subtracting it would falsely project a dip.
    def internal_cash_transfer?(recurring_transaction)
      return false unless recurring_transaction.transfer?

      @cash_account_ids.include?(recurring_transaction.account_id) &&
        @cash_account_ids.include?(recurring_transaction.destination_account_id)
    end

    # Returns { Date => net outflow } from recurring transactions due soon.
    # Sure sign convention: positive amount = outflow (reduces cash).
    def scheduled_movements
      movements = Hash.new(0.0)

      family.recurring_transactions.expected_soon.find_each do |rt|
        entry = rt.projected_entry
        next unless entry
        next unless entry.date.between?(Date.current, Date.current + PROJECTION_DAYS.days)
        next if internal_cash_transfer?(rt)

        amount = convert_to_family_currency(entry.amount, entry.currency)
        movements[entry.date.to_date] += amount
      end

      movements
    end
end
