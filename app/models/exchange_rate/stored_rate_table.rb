# Stored rates from several currencies into one, for many dates, loaded up
# front. For each date it picks what ExchangeRate.find_stored_rate would: the
# usable rate on or before the date, however old, else the earliest after it
# (the rule Balance::ChartSeriesBuilder converts balances with). Never calls a
# provider, so it is safe while serving a request; the query count does not
# grow with the number of dates.
class ExchangeRate::StoredRateTable
  def initialize(from:, to:, dates:)
    @to = to
    @rates = {}
    @fallback = {}

    currencies = Array(from).compact.uniq - [ to ]
    first, last = Array(dates).compact.minmax
    return if currencies.empty? || first.nil?

    ExchangeRate.where(from_currency: currencies, to_currency: to, date: first..last)
                .where("exchange_rates.rate > 0")
                .order(:date)
                .pluck(:from_currency, :date, :rate)
                .each { |currency, date, rate| (@rates[currency] ||= []) << [ date, rate ] }

    # Covers dates before the first rate inside the range.
    currencies.each { |currency| @fallback[currency] = ExchangeRate.find_stored_rate(from: currency, to: to, date: first)&.rate }
  end

  def rate(from, date)
    return 1 if from == @to

    stored = @rates[from]&.reverse_each&.find { |rate_date, _| rate_date <= date }
    stored ? stored.last : @fallback[from]
  end

  # nil when there is no usable rate: callers leave the amount out instead of
  # counting it at 1.
  def convert(amount, from:, date:)
    rate = rate(from, date)
    rate && amount.to_d * rate
  end
end
