# Frankfurter (https://frankfurter.dev), a free, keyless, open-source FX rates
# API backed by exchange rates blended across multiple central banks (ECB,
# FED, BOC, etc). No auth, no key, no published rate limit, and self-hostable
# (out of scope here, we just consume the public instance, with
# FRANKFURTER_URL as an escape hatch for self-hosters later).
#
# This targets Frankfurter's v2 API (https://api.frankfurter.dev/v2), not v1.
# Per Frankfurter's own root endpoint, v1 is status "frozen" (stable, no new
# features) while v2 is status "current" (the actively developed version)
# and covers far more currencies (201 across 84 central banks, vs v1's ~30
# ECB-only). v2 also carries forward weekends/holidays server-side (a single
# date lookup on a non-trading day returns the last known rate directly), so
# unlike v1 this provider does not need its own lookback-window logic.
class Provider::Frankfurter < Provider
  include ExchangeRateConcept, RateLimitable
  extend SslConfigurable

  Error = Class.new(Provider::Error)
  RateLimitError = Class.new(Error)

  # No published rate limit, but a light throttle is cheap insurance.
  MIN_REQUEST_INTERVAL = 0.15

  def initialize
    # No API key required, public endpoint only.
  end

  def healthy?
    with_provider_response do
      body = get_json("/currencies")
      raise Error, "Frankfurter currencies endpoint returned no data" if body.blank?
      true
    end
  end

  def usage
    with_provider_response do
      UsageData.new(used: nil, limit: nil, utilization: nil, plan: "Free (no key required)")
    end
  end

  # GET /rate/{base}/{quote}?date=... -> { date:, base:, quote:, rate: }.
  # Frankfurter carries forward weekends/holidays itself, so the returned
  # date may differ from the requested one but is never simply missing.
  def fetch_exchange_rate(from:, to:, date:)
    from = sanitize_currency(from)
    to = sanitize_currency(to)

    with_provider_response do
      if from == to
        Rate.new(date: date, from: from, to: to, rate: 1.0)
      else
        body = get_json("/rate/#{from}/#{to}", "date" => date.to_s)
        raise Error, "Unexpected Frankfurter response shape" unless body.is_a?(Hash) && body["rate"]

        begin
          parsed_date = Date.parse(body["date"].to_s)
        rescue Date::Error => e
          raise Error, "Invalid date in Frankfurter response: #{e.message}"
        end

        Rate.new(date: parsed_date, from: from, to: to, rate: body["rate"].to_f)
      end
    end
  end

  def fetch_exchange_rates(from:, to:, start_date:, end_date:)
    from = sanitize_currency(from)
    to = sanitize_currency(to)

    with_provider_response do
      if from == to
        generate_same_currency_rates(from, to, start_date, end_date)
      else
        exchange_rates(from, to, start_date, end_date)
      end
    end
  end

  def max_history_days
    nil # Backed by central bank reference rates going back decades, no bounded window.
  end

  private

    # from/to are interpolated directly into the URL path in
    # fetch_exchange_rate (GET /rate/{from}/{to}), so strip anything that
    # isn't a letter before use - real ISO 4217 codes are always A-Z anyway.
    def sanitize_currency(code)
      code.to_s.upcase.gsub(/[^A-Z]/, "")
    end

    def base_url
      ENV["FRANKFURTER_URL"].presence || "https://api.frankfurter.dev/v2"
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

    # GET /rates?base=...&quotes=...&from=...&to=... -> a flat array of
    # { date:, base:, quote:, rate: } records, one per day in range (v2
    # carries forward weekends/holidays itself, so every calendar day in the
    # range is present, not just trading days).
    def exchange_rates(from, to, start_date, end_date)
      body = get_json("/rates", "base" => from, "quotes" => to, "from" => start_date.to_s, "to" => end_date.to_s)
      raise Error, "Unexpected Frankfurter response shape (expected an array)" unless body.is_a?(Array)

      body.filter_map do |entry|
        next nil unless entry.is_a?(Hash) && entry["quote"] == to

        rate_value = entry["rate"]
        next nil if rate_value.nil?

        Rate.new(date: Date.parse(entry["date"].to_s), from: from, to: to, rate: rate_value.to_f)
      end.sort_by(&:date)
    rescue Date::Error => e
      raise Error, "Invalid date in Frankfurter response: #{e.message}"
    end
end
