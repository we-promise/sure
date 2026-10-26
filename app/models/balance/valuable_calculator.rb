# Daily balances for a Gems and Bullion account, computed from its items
# rather than from entries: each day, every item held is valued at the latest
# stored ExchangeRate on or before that day (see ValuablePriceHistory), so
# weekends and holidays carry the last close forward. Only stored rates are
# read; no provider is called.
#
# Manually valued items count at their manual value. A spot-valued item with
# no stored rate yet counts at its purchase cost. A purchase is a non-cash
# inflow at its value that day, and the rest of each day's change is the
# market move, so end_balance always equals the computed value.
class Balance::ValuableCalculator < Balance::BaseCalculator
  def incremental?
    false
  end

  def calculation_start_date
    @calculation_start_date ||= items.map(&:acquired_on).min || Date.current
  end

  def calculate
    prev_value = 0

    (calculation_start_date..Date.current).map do |date|
      held = items.select { |item| item.acquired_on <= date }
      # Rounded to the balances column scale so the generated end_balance matches exactly.
      value = held.sum(0) { |item| value_of(item, date) }.round(4)
      inflows = held.select { |item| item.acquired_on == date }.sum(0) { |item| value_of(item, date) }.round(4)

      balance = build_balance(
        date: date,
        balance: value,
        cash_balance: 0,
        start_non_cash_balance: prev_value,
        non_cash_inflows: inflows,
        net_market_flows: value - prev_value - inflows
      )
      prev_value = value
      balance
    end
  end

  private
    def items
      @items ||= account.valuable.items.to_a
    end

    def value_of(item, date)
      return item.value_for if item.manual_value? || !item.spot_valued?

      rate = rate_on(item.quote_symbol, date)
      rate ? item.value_for(rate) : item.total_cost_amount
    end

    def rate_on(symbol, date)
      rows = rates.fetch(symbol, [])
      after = rows.bsearch_index { |rate_date, _| rate_date > date } || rows.size
      rows[after - 1].last if after.positive?
    end

    # { symbol => [[date, rate], ...] } in date order, including the latest
    # rate before the first item so its first days can carry it forward.
    def rates
      @rates ||= begin
        symbols = items.select(&:spot_valued?).map(&:quote_symbol).compact.uniq
        scope = ExchangeRate.where(from_currency: symbols, to_currency: account.currency)
        earlier = symbols.filter_map { |symbol| scope.where(from_currency: symbol).where(date: ...calculation_start_date).order(date: :desc).first }

        (earlier + scope.where(date: calculation_start_date..Date.current).order(:date).to_a)
          .group_by(&:from_currency)
          .transform_values { |rows| rows.map { |row| [ row.date, row.rate.to_d ] } }
      end
    end
end
