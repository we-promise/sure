# Frankfurter (https://frankfurter.dev), a free, keyless, open-source FX rates
# API backed by ECB daily reference rates. No auth, no key, no published rate
# limit, and self-hostable (out of scope here, we just consume the public
# instance, with FRANKFURTER_URL as an escape hatch for self-hosters later).
#
# Frankfurter computes cross-currency rates server-side (e.g. INR->CAD
# triangulated via EUR), so a single request gives the direct rate. No need
# to fetch two legs and divide.
#
# Weekends/ECB holidays simply have no entry in the response (no row, not a
# zero), which Sure's ExchangeRate::Importer already gapfills via
# last-observation-carried-forward, so no special handling is needed here
# beyond looking back to the nearest prior date for single-date lookups.
class Provider::Frankfurter < Provider
  include ExchangeRateConcept, RateLimitable
  extend SslConfigurable

  Error = Class.new(Provider::Error)
  RateLimitError = Class.new(Error)

  # No published rate limit, but a light throttle is cheap insurance.
  MIN_REQUEST_INTERVAL = 0.15

  # Weekends/ECB holidays return no data for the exact date, so a single-date
  # lookup falls back to the nearest prior date within this window.
  RATE_LOOKBACK_DAYS = 10

  def initialize
    # No API key required, public endpoint only.
  end

  def healthy?
    with_provider_response do
      body = get_json("/v1/currencies")
      raise Error, "Frankfurter currencies endpoint returned no data" if body.blank?
      true
    end
  end

  def usage
    with_provider_response do
      UsageData.new(used: nil, limit: nil, utilization: nil, plan: "Free (no key required)")
    end
  end

  def fetch_exchange_rate(from:, to:, date:)
    from = from.to_s.upcase
    to = to.to_s.upcase

    with_provider_response do
      if from == to
        Rate.new(date: date, from: from, to: to, rate: 1.0)
      else
        rates = exchange_rates(from, to, date - RATE_LOOKBACK_DAYS, date)
        raise Error, "No Frankfurter FX rate for #{from}/#{to} on #{date}" if rates.blank?

        rates.find { |r| r.date == date } ||
          rates.select { |r| r.date <= date }.max_by(&:date) ||
          rates.first
      end
    end
  end

  def fetch_exchange_rates(from:, to:, start_date:, end_date:)
    from = from.to_s.upcase
    to = to.to_s.upcase

    with_provider_response do
      if from == to
        generate_same_currency_rates(from, to, start_date, end_date)
      else
        exchange_rates(from, to, start_date, end_date)
      end
    end
  end

  def max_history_days
    nil # ECB reference rates go back to 1999, no bounded window.
  end

  private

    def base_url
      ENV["FRANKFURTER_URL"].presence || "https://api.frankfurter.dev"
    end

    def get_json(path, params = {})
      throttle_request
      response = client.get("#{base_url}#{path}") do |req|
        params.each { |k, v| req.params[k] = v }
      end
      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise Error, "Invalid Frankfurter response: #{e.message}"
    end

    def client
      @client ||= Faraday.new(url: base_url, ssl: self.class.faraday_ssl_options) do |faraday|
        faraday.options.open_timeout = 5
        faraday.options.timeout      = 20

        faraday.request(:retry, {
          max: 3,
          interval: 0.5,
          interval_randomness: 0.5,
          backoff_factor: 2,
          exceptions: Faraday::Retry::Middleware::DEFAULT_EXCEPTIONS + [ Faraday::ConnectionFailed ]
        })

        faraday.request :json
        faraday.response :raise_error
        faraday.headers["Accept"] = "application/json"
      end
    end

    def generate_same_currency_rates(from, to, start_date, end_date)
      (start_date..end_date).map do |date|
        Rate.new(date: date, from: from, to: to, rate: 1.0)
      end
    end

    # Frankfurter's date-range envelope: { "amount", "base", "start_date",
    # "end_date", "rates": { "2024-03-18" => { "CAD" => 0.01632 }, ... } }.
    # Missing dates (weekends/holidays) simply have no key, not an error.
    def exchange_rates(from, to, start_date, end_date)
      body = get_json("/v1/#{start_date}..#{end_date}", "from" => from, "to" => to)
      raise Error, "Unexpected Frankfurter response shape (no rates key)" unless body.is_a?(Hash) && body.key?("rates")

      rates_by_date = body["rates"] || {}

      rates_by_date.filter_map do |date_str, currencies|
        rate_value = currencies.is_a?(Hash) ? currencies[to] : nil
        next nil if rate_value.nil?

        Rate.new(date: Date.parse(date_str), from: from, to: to, rate: rate_value.to_f)
      end.sort_by(&:date)
    rescue Date::Error => e
      raise Error, "Invalid date in Frankfurter response: #{e.message}"
    end
end
