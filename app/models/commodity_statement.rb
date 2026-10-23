# Family-level commodity figures (shaped like InvestmentStatement but kept
# separate): value, cost basis, unrealized and realized P&L and weights, per
# metal and per location. Amounts are in the family currency; item amounts are
# converted from their account currency at today's rate.
class CommodityStatement
  attr_reader :family, :user

  # Aggregate of a group of held items. Monetary figures are nil when any item
  # lacks a price or exchange rate — an unknown total, never a partial one.
  class Totals
    attr_reader :items, :currency

    def initialize(items, currency:)
      @items = items
      @currency = currency
    end

    def fine_grams
      items.sum(BigDecimal(0)) { |i| i.fine_grams }
    end

    def gross_grams
      items.sum(BigDecimal(0)) { |i| i.gross_grams }
    end

    def melt_value
      @melt_value ||= sum_money { |i| i.melt_value }
    end

    def cost_basis
      return @cost_basis if defined?(@cost_basis)

      bases = items.map(&:cost_basis)
      @cost_basis = if bases.any?(&:nil?)
        nil
      else
        Commodity::Item::CostBasis.new(
          metal: sum_converted(bases.map(&:metal)),
          premium: sum_converted(bases.map(&:premium)),
          other: sum_converted(bases.map(&:other))
        )
      end
    rescue Money::ConversionError
      @cost_basis = nil
    end

    def unrealized_trend
      melt_value && cost_basis && Trend.new(current: melt_value, previous: cost_basis.total)
    end

    def metal_gain
      melt_value && cost_basis && melt_value - cost_basis.metal
    end

    def realisable_value
      return nil if items.none?(&:sell_back_mode)

      sum_money { |i| i.realisable_value || i.melt_value }
    end

    private
      def sum_money
        values = items.map { |i| yield(i) }
        values.any?(&:nil?) ? nil : sum_converted(values)
      rescue Money::ConversionError
        nil
      end

      def sum_converted(values)
        values.sum(Money.new(0, currency)) { |m| m.exchange_to(currency) }
      end
  end

  def initialize(family, user: nil, accounts: nil, currency: nil)
    @family = family
    @user = user
    @accounts = accounts
    @currency = currency
  end

  def currency
    @currency || family.currency
  end

  # Where the current prices come from, for labelling ("spot" vs "futures").
  def price_sources
    codes = held_items.map(&:code).uniq
    codes.filter_map { |code| Commodity::Price.latest_on(code, Date.current)&.source }.uniq
  end

  def accounts
    @accounts ||= begin
      scope = family.accounts.visible.included_in_reports.where(accountable_type: "Commodity")
      scope = scope.included_in_finances_for(user) if user
      scope
    end
  end

  def items
    @items ||= Commodity::Item.where(account: accounts).includes(:account, :location, :sales).order(:purchase_date, :created_at).to_a
  end

  def held_items
    items.select(&:held?)
  end

  def any?
    items.any?
  end

  def total
    @total ||= Totals.new(held_items, currency: currency)
  end

  # [[Commodity::Metal, Totals], ...] in configuration order.
  def by_metal
    grouped = held_items.group_by(&:code)
    Commodity::CATALOG.filter_map { |metal| [ metal, Totals.new(grouped[metal.code], currency: currency) ] if grouped[metal.code] }
  end

  # [[Commodity::Location or nil, Totals], ...] sorted by name, unassigned last.
  def by_location
    held_items.group_by(&:location)
              .sort_by { |location, _| location ? [ 0, location.name.downcase ] : [ 1, "" ] }
              .map { |location, group| [ location, Totals.new(group, currency: currency) ] }
  end

  LOCATION_COLORS = %w[#1570EF #CA8A04 #06AED4 #F23E94 #12B76A #7A5AF8 #737373].freeze

  # Melt value per location for the allocation donut.
  def location_allocation
    rows = by_location.filter_map do |location, totals|
      [ location, totals.melt_value ] if totals.melt_value&.positive?
    end
    sum = rows.sum { |_, value| value.amount }
    return [] if sum.zero?

    rows.each_with_index.map do |(location, value), index|
      {
        id: location&.id || "unassigned",
        name: location&.name,
        amount: value.amount.round(2).to_f,
        money: value,
        color: LOCATION_COLORS[index % LOCATION_COLORS.size],
        percentage: (value.amount / sum * 100).round(1).to_f
      }
    end
  end

  def sales(period: nil)
    all = items.flat_map(&:sales)
    period ? all.select { |s| period.date_range.cover?(s.date) } : all
  end

  # Realized P&L of sales in the period, or nil when any sale's rate is unknown.
  def realized_gain(period: nil, code: nil)
    selected = sales(period: period).select { |s| code.nil? || s.item.code == code }
    trends = selected.map(&:realized_gain_loss)
    return nil if trends.any?(&:nil?)

    trends.sum(Money.new(0, currency)) { |t| t.value.exchange_to(currency) }
  rescue Money::ConversionError
    nil
  end

  # Value over time with a per-metal breakdown, in the payload shape of the
  # net-worth breakdown chart (net_worth_chart_controller).
  def value_series(period:)
    return nil unless any?

    start_date = [ period.start_date, items.map(&:purchase_date).min ].max
    end_date = period.end_date
    prices = Commodity::PriceSeries.new(codes: items.map(&:code), currency: currency, start_date: start_date, end_date: end_date)
    step = { "1 month" => 1.month, "1 week" => 1.week }.fetch(period.interval, 1.day)

    dates = []
    date = start_date
    while date <= end_date
      dates << date
      date += step
    end
    dates << end_date unless dates.last == end_date

    previous = nil
    values = dates.filter_map do |d|
      held = by_code_held_on(d).map { |code, ozt| [ Commodity.metal(code), prices.price_on(code, d), ozt ] }
      # A date where a held metal has no known price (or rate) is left out
      # rather than plotted as worth zero.
      next if held.any? { |_, price, _| price.nil? }

      groups = held.map do |metal, price, ozt|
        { name: metal.name, color: metal.color, classification: "asset", value: Money.new((price * ozt).round(2), currency) }
      end
      total = Money.new(groups.sum { |g| g[:value].amount }, currency)
      point = {
        date: d,
        date_formatted: I18n.l(d, format: :long),
        value: total,
        trend: Trend.new(current: total, previous: previous || total),
        assets: total,
        liabilities: Money.new(0, currency),
        groups: groups
      }
      previous = total
      point
    end

    return nil if values.empty?

    { start_date: start_date, end_date: end_date, interval: period.interval, trend: Trend.new(current: values.last[:value], previous: values.first[:value]), values: values }
  end

  private
    def by_code_held_on(date)
      items.each_with_object(Hash.new(BigDecimal(0))) do |item, held|
        next if item.purchase_date > date

        held_qty = item.quantity - item.sales.sum { |s| s.date <= date ? s.quantity : 0 }
        held[item.code] += item.fine_troy_ounces(held_qty) if held_qty.positive?
      end
    end
end
