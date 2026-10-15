# Preloaded commodity prices and exchange rates for valuing inventory over a
# date range without per-day queries. Prices and rates are carried forward
# from the last known day; before the first known price, the price is nil.
class Commodity::PriceSeries
  def initialize(codes:, currency:, start_date:, end_date: Date.current)
    @codes = codes.uniq
    @currency = currency
    @start_date = start_date - Commodity::Price::LOOKBACK_DAYS
    @end_date = end_date
  end

  # Price per troy ounce in `currency` on `date`, or nil when unknown.
  def price_on(code, date)
    price = last_on_or_before(prices[code], date)
    return nil unless price

    rate = price[:currency] == currency ? 1 : last_on_or_before(rates[price[:currency]], date)&.dig(:rate)
    rate && price[:price] * rate
  end

  private
    attr_reader :codes, :currency, :start_date, :end_date

    def last_on_or_before(series, date)
      return nil if series.blank?

      index = series.bsearch_index { |row| row[:date] > date } || series.size
      index.positive? ? series[index - 1] : nil
    end

    def prices
      @prices ||= Commodity::Price
        .where(code: codes, date: start_date..end_date)
        .order(:date)
        .pluck(:code, :date, :price, :currency)
        .group_by(&:first)
        .transform_values { |rows| rows.map { |_, date, price, cur| { date: date, price: price, currency: cur } } }
    end

    def rates
      @rates ||= begin
        currencies = prices.values.flatten.map { |p| p[:currency] }.uniq - [ currency ]
        ExchangeRate
          .where(from_currency: currencies, to_currency: currency, date: start_date..end_date)
          .order(:date)
          .pluck(:from_currency, :date, :rate)
          .group_by(&:first)
          .transform_values { |rows| rows.map { |_, date, rate| { date: date, rate: rate } } }
      end
    end
end
