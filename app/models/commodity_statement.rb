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

  def initialize(family, user: nil, accounts: nil)
    @family = family
    @user = user
    @accounts = accounts
  end

  def currency
    family.currency
  end

  def accounts
    @accounts ||= begin
      scope = family.accounts.visible.where(accountable_type: "Commodity")
      scope = scope.accessible_by(user) if user
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

  # Value over time per metal for charting:
  # [{ date:, value:, groups: [{ name:, color:, value: }] }, ...]
  def value_series(period:)
    return [] unless any?

    start_date = [ period.start_date, items.map(&:purchase_date).min ].max
    series = Commodity::PriceSeries.new(codes: items.map(&:code), currency: currency, start_date: start_date, end_date: period.end_date)
    step = { "1 month" => 1.month, "1 week" => 1.week }.fetch(period.interval, 1.day)

    dates = []
    date = start_date
    while date <= period.end_date
      dates << date
      date += step
    end
    dates << period.end_date unless dates.last == period.end_date

    dates.map do |d|
      groups = by_code_held_on(d).map do |code, ozt|
        metal = Commodity.metal(code)
        price = series.price_on(code, d)
        { name: metal.name, color: metal.color, value: price ? (price * ozt).round(2).to_f : 0 }
      end
      { date: d, value: groups.sum { |g| g[:value] }, groups: groups }
    end
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
