# Daily balances for a Commodity account, computed from the inventory rather
# than from entries: for each day, the fine troy ounces held per commodity
# times that day's price, converted to the account currency.
#
# Purchases and sales are recorded as non-cash inflows/outflows at the day's
# melt value, and the remaining change is the market move, so the generated
# end_balance always equals the computed melt value.
class Balance::CommodityCalculator < Balance::BaseCalculator
  def incremental?
    false
  end

  def calculation_start_date
    @calculation_start_date ||= items.map(&:purchase_date).min || Date.current
  end

  def calculate
    prev_value = 0

    (calculation_start_date..Date.current).map do |date|
      # Rounded to the balances column scale so the generated end_balance matches exactly.
      value = held_on(date).sum(0) { |code, ozt| value_of(code, ozt, date) }.round(4)
      inflows = movements_on(date, :purchases).sum(0) { |code, ozt| value_of(code, ozt, date) }.round(4)
      outflows = movements_on(date, :sales).sum(0) { |code, ozt| value_of(code, ozt, date) }.round(4)

      balance = build_balance(
        date: date,
        balance: value,
        cash_balance: 0,
        start_non_cash_balance: prev_value,
        non_cash_inflows: inflows,
        non_cash_outflows: outflows,
        net_market_flows: value - prev_value - inflows + outflows
      )
      prev_value = value
      balance
    end
  end

  private
    def items
      @items ||= account.commodity_items.includes(:sales).to_a
    end

    # { code => fine ozt held at end of day }
    def held_on(date)
      items.each_with_object(Hash.new(0)) do |item, held|
        next if item.purchase_date > date

        sold = item.sales.sum { |s| s.date <= date ? s.quantity : 0 }
        held[item.code] += item.fine_troy_ounces(item.quantity - sold)
      end
    end

    def movements_on(date, kind)
      @movements ||= begin
        moves = Hash.new { |h, k| h[k] = Hash.new(0) }
        items.each do |item|
          moves[[ item.purchase_date, :purchases ]][item.code] += item.fine_troy_ounces(item.quantity)
          item.sales.each { |sale| moves[[ sale.date, :sales ]][item.code] += item.fine_troy_ounces(sale.quantity) }
        end
        moves
      end
      @movements.fetch([ date, kind ], {})
    end

    def value_of(code, ozt, date)
      return 0 if ozt.zero?

      price = price_on(code, date)
      price ? price * ozt : 0
    end

    # Price per ozt in the account currency, carrying the last known price and
    # rate forward. Before the first known price the item contributes nothing.
    def price_on(code, date)
      price = last_on_or_before(prices[code], date)
      return nil unless price

      rate = price[:currency] == account.currency ? 1 : last_on_or_before(rates[price[:currency]], date)&.dig(:rate)
      rate && price[:price] * rate
    end

    def last_on_or_before(series, date)
      return nil if series.blank?

      index = series.bsearch_index { |row| row[:date] > date }
      index = index.nil? ? series.size - 1 : index - 1
      index >= 0 ? series[index] : nil
    end

    def prices
      @prices ||= Commodity::Price
        .where(code: items.map(&:code).uniq, date: (calculation_start_date - Commodity::Price::LOOKBACK_DAYS)..Date.current)
        .order(:date)
        .pluck(:code, :date, :price, :currency)
        .group_by(&:first)
        .transform_values { |rows| rows.map { |_, date, price, currency| { date: date, price: price, currency: currency } } }
    end

    def rates
      @rates ||= begin
        currencies = prices.values.flatten.map { |p| p[:currency] }.uniq - [ account.currency ]
        ExchangeRate
          .where(from_currency: currencies, to_currency: account.currency, date: (calculation_start_date - Commodity::Price::LOOKBACK_DAYS)..Date.current)
          .order(:date)
          .pluck(:from_currency, :date, :rate)
          .group_by(&:first)
          .transform_values { |rows| rows.map { |_, date, rate| { date: date, rate: rate } } }
      end
    end
end
