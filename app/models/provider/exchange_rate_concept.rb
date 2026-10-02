module Provider::ExchangeRateConcept
  extend ActiveSupport::Concern

  Rate = Data.define(:date, :from, :to, :rate)

  # Prepended to every provider that includes this concept, so each one, and
  # any added later, only hands callers rates that can convert an amount (see
  # ExchangeRate.valid_rate?). Providers occasionally answer with a zero rate;
  # stored, it turned every balance in that currency into zero
  # (we-promise/sure#1187).
  module RateValidation
    # An unusable rate is reported as a failed lookup, which callers already
    # handle, instead of a successful one they would store and convert with.
    def fetch_exchange_rate(from:, to:, date:)
      response = super
      return response unless response.success?
      return response if ExchangeRate.valid_rate?(response.data&.rate)

      report_invalid_exchange_rates(from:, to:, rates: [ response.data ])

      Provider::Response.new(
        success?: false,
        data: nil,
        error: self.class::Error.new("#{self.class.name} returned an invalid exchange rate for #{from}/#{to} on #{date}: #{response.data&.rate.inspect}")
      )
    end

    # Unusable rows are dropped, so the importer treats their dates as gaps and
    # carries the previous valid rate forward.
    def fetch_exchange_rates(from:, to:, start_date:, end_date:)
      response = super
      return response unless response.success?

      valid_rates, invalid_rates = Array(response.data).partition { |rate| ExchangeRate.valid_rate?(rate&.rate) }
      return response if invalid_rates.empty?

      report_invalid_exchange_rates(from:, to:, rates: invalid_rates)

      Provider::Response.new(success?: true, data: valid_rates, error: nil)
    end

    private
      def report_invalid_exchange_rates(from:, to:, rates:)
        message = "#{self.class.name} returned #{rates.size} invalid exchange rate(s) for #{from}/#{to}"
        Rails.logger.warn(message)

        DebugLogEntry.capture(
          category: "exchange_rates",
          level: "warn",
          message: message,
          source: self.class.name,
          provider: self,
          metadata: {
            from: from,
            to: to,
            rates: rates.map { |rate| { date: rate&.date&.to_s, rate: rate&.rate.inspect } }
          }
        )
      end
  end

  included do
    prepend RateValidation
  end

  def fetch_exchange_rate(from:, to:, date:)
    raise NotImplementedError, "Subclasses must implement #fetch_exchange_rate"
  end

  def fetch_exchange_rates(from:, to:, start_date:, end_date:)
    raise NotImplementedError, "Subclasses must implement #fetch_exchange_rates"
  end

  # Maximum number of calendar days of historical FX data the provider can
  # return. Returns nil when the provider has no known limit (unbounded).
  # Callers should clamp start_date when non-nil to avoid requesting data
  # beyond this window. Override in subclasses with provider-specific limits.
  def max_history_days
    nil
  end
end
