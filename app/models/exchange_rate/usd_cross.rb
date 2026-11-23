# Derives a pair the provider does not quote from its two USD legs:
# X→Y = X→USD × USD→Y. Providers quote nearly every currency against USD but
# far fewer crosses between two others; Yahoo Finance has KZT/USD and USD/RUB
# with full history, yet no KZT/RUB at all.
class ExchangeRate::UsdCross
  # Errors every provider names this way when the provider itself is failing,
  # not the pair; the USD legs would only fail the same way. Others (a network
  # error, an unknown pair) look alike, as Yahoo Finance reports both as Error.
  PROVIDER_FAILURES = %w[RateLimitError AuthenticationError].freeze

  # Avoid repeating unsuccessful USD-leg requests for the same pair and dates
  # during a sync of many entries or holdings.
  MISS_TTL = 1.hour

  def initialize(provider)
    @provider = provider
  end

  # Rate[] for dates with both USD legs. Callers can reuse a completed cross
  # when a date has no matching quotes. `error` is why the direct pair failed.
  # [] when either side is USD, the provider itself is failing or cannot derive
  # a pair (see Provider::ExchangeRateConcept#usd_cross?), it has quoted
  # this pair before (so the failure is an outage, and a derived rate would
  # be cached in place of its own), or the legs yield no usable cross. The
  # latter is cached for MISS_TTL unless the provider itself failed.
  def rates(from:, to:, start_date:, end_date:, error: nil)
    return [] if from == to || [ from, to ].include?("USD")
    return [] if provider_failure?(error)
    return [] if @provider.respond_to?(:usd_cross?) && !@provider.usd_cross?
    return [] if Rails.cache.exist?(miss_key(from, to, start_date, end_date))
    # A pair is derived until the provider has answered it once, so a transient failure before then keeps the rates derived at that point.
    return [] if ExchangeRatePair.for_pair(from: from, to: to).quoted_directly?

    to_usd = leg(from, "USD", start_date, end_date)
    return miss(from, to, start_date, end_date) if to_usd.empty?

    from_usd = leg("USD", to, start_date, end_date)
    return miss(from, to, start_date, end_date) if from_usd.empty?

    from_usd_by_date = from_usd.index_by(&:date)
    crossed = to_usd.filter_map do |first|
      second = from_usd_by_date[first.date]
      next unless second

      # Two tiny legs can multiply to under 5e-13, which rounds to a zero rate.
      rate = (BigDecimal(first.rate.to_s) * BigDecimal(second.rate.to_s)).round(12)
      next unless ExchangeRate.valid_rate?(rate)

      Provider::ExchangeRateConcept::Rate.new(date: first.date, from: from, to: to, rate: rate)
    end

    return miss(from, to, start_date, end_date) if crossed.empty?

    Rails.cache.delete(miss_key(from, to, start_date, end_date))
    direct_error = error&.message
    report("info", "Derived #{crossed.size} #{from}/#{to} rates from #{@provider.class.name} USD rates between #{start_date} and #{end_date}; direct pair: #{direct_error || "no rates"}",
           from:, to:, start_date:, end_date:, direct_error:)
    crossed
  end

  private
    def leg(from, to, start_date, end_date)
      response = @provider.fetch_exchange_rates(from: from, to: to, start_date: start_date, end_date: end_date)
      return response.data.sort_by(&:date) if response.success?

      @provider_failing ||= provider_failure?(response.error)
      error = response.error.message
      report("warn", "#{@provider.class.name} could not fetch the #{from}/#{to} leg between #{start_date} and #{end_date}: #{error}",
             from:, to:, start_date:, end_date:, error:)
      []
    end

    def provider_failure?(error)
      error.class.name.to_s.demodulize.in?(PROVIDER_FAILURES)
    end

    def miss_key(from, to, start_date, end_date)
      "usd_cross_miss:#{@provider.class.name}:#{from}:#{to}:#{start_date}:#{end_date}"
    end

    # A failed derivation says nothing about the pair if the provider is down.
    def miss(from, to, start_date, end_date)
      Rails.cache.write(miss_key(from, to, start_date, end_date), true, expires_in: MISS_TTL) unless @provider_failing
      []
    end

    # Derived rates are stored like direct ones, so the debug log is the only
    # record of which dates came from the USD legs.
    def report(level, message, **metadata)
      Rails.logger.public_send(level, message)
      DebugLogEntry.capture(category: "exchange_rates", level: level, message: message, source: self.class.name, provider: @provider, metadata: metadata)
    end
end
