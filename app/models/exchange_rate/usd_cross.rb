# Derives a pair the provider does not quote from its two USD legs:
# X→Y = X→USD × USD→Y. Providers quote nearly every currency against USD but
# far fewer crosses between two others; Yahoo Finance has KZT/USD and USD/RUB
# with full history, yet no KZT/RUB at all.
class ExchangeRate::UsdCross
  def initialize(provider)
    @provider = provider
  end

  # Rate[] dated like the X→USD leg, each multiplied by the latest USD→Y rate
  # on or before that date. [] when either side is USD or a leg has no rates.
  def rates(from:, to:, start_date:, end_date:)
    return [] if from == to || [ from, to ].include?("USD")

    to_usd = leg(from, "USD", start_date, end_date)
    return [] if to_usd.empty?

    from_usd = leg("USD", to, start_date, end_date)
    i = -1
    to_usd.filter_map do |first|
      i += 1 while i + 1 < from_usd.size && from_usd[i + 1].date <= first.date
      next if i.negative?

      rate = BigDecimal(first.rate.to_s) * BigDecimal(from_usd[i].rate.to_s)
      Provider::ExchangeRateConcept::Rate.new(date: first.date, from: from, to: to, rate: rate.round(12))
    end
  end

  private
    def leg(from, to, start_date, end_date)
      response = @provider.fetch_exchange_rates(from: from, to: to, start_date: start_date, end_date: end_date)
      response.success? ? response.data.select { |r| r.rate.to_f.positive? }.sort_by(&:date) : []
    end
end
