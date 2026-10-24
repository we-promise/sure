# Derives a pair the provider does not quote from its two USD legs:
# X→Y = X→USD × USD→Y. Providers quote nearly every currency against USD but
# far fewer crosses between two others; Yahoo Finance has KZT/USD and USD/RUB
# with full history, yet no KZT/RUB at all.
class ExchangeRate::UsdCross
  # Errors every provider names this way when the provider itself is failing,
  # not the pair; the USD legs would only fail the same way. Others (a network
  # error, an unknown pair) look alike, as Yahoo Finance reports both as Error.
  PROVIDER_FAILURES = %w[RateLimitError AuthenticationError].freeze

  def initialize(provider)
    @provider = provider
  end

  # Rate[] dated like the X→USD leg, each multiplied by the latest USD→Y rate
  # on or before that date. `error` is why the direct pair failed, when it did.
  # [] when either side is USD, the provider itself is failing, or a leg has
  # no rates.
  def rates(from:, to:, start_date:, end_date:, error: nil)
    return [] if from == to || [ from, to ].include?("USD")
    return [] if error.class.name.to_s.demodulize.in?(PROVIDER_FAILURES)

    to_usd = leg(from, "USD", start_date, end_date)
    return [] if to_usd.empty?

    from_usd = leg("USD", to, start_date, end_date)
    i = -1
    crossed = to_usd.filter_map do |first|
      i += 1 while i + 1 < from_usd.size && from_usd[i + 1].date <= first.date
      next if i.negative?

      # Two tiny legs can multiply to under 5e-13, which rounds to a zero rate.
      rate = (BigDecimal(first.rate.to_s) * BigDecimal(from_usd[i].rate.to_s)).round(12)
      next unless ExchangeRate.valid_rate?(rate)

      Provider::ExchangeRateConcept::Rate.new(date: first.date, from: from, to: to, rate: rate)
    end

    if crossed.any?
      direct_error = error&.message
      report("info", "Derived #{crossed.size} #{from}/#{to} rates from #{@provider.class.name} USD rates between #{start_date} and #{end_date}; direct pair: #{direct_error || "no rates"}",
             from:, to:, start_date:, end_date:, direct_error:)
    end
    crossed
  end

  private
    def leg(from, to, start_date, end_date)
      response = @provider.fetch_exchange_rates(from: from, to: to, start_date: start_date, end_date: end_date)
      return response.data.sort_by(&:date) if response.success?

      error = response.error.message
      report("warn", "#{@provider.class.name} could not fetch the #{from}/#{to} leg between #{start_date} and #{end_date}: #{error}",
             from:, to:, start_date:, end_date:, error:)
      []
    end

    # Derived rates are stored like direct ones, so the debug log is the only
    # record of which dates came from the USD legs.
    def report(level, message, **metadata)
      Rails.logger.public_send(level, message)
      DebugLogEntry.capture(category: "exchange_rates", level: level, message: message, source: self.class.name, provider: @provider, metadata: metadata)
    end
end
