# Mansa API (mansaapi.com) — African stock exchange data, including NGX
# (Nigerian Exchange). Added because none of Sure's existing securities
# providers cover NGX: TwelveData/YahooFinance don't list it, and EODHD's own
# MIC-code map in this codebase (see Provider::Eodhd::MIC_TO_EODHD_EXCHANGE)
# has no XNSA entry despite EODHD's marketing pages listing Nigeria as a
# covered exchange generally — confirmed absent, not just unconfirmed.
#
# Free tier: 100 requests/day, no card required, covers quotes/search/exchange
# metadata. Per-stock historical OHLCV (the /history endpoint) requires a paid
# Pro plan — see #fetch_security_prices below for how that's handled here.
#
# Response shape confirmed live (2026-09-17) against real NGX data:
#   GET .../exchanges/NGX/stocks/MTNN ->
#     {"success":true,"data":{"ticker":...,"name":...,"price":...,...},
#      "meta":{"exchange":"NGX","currency":"NGN",...}}
#   GET .../markets/search?q=MTN&exchange=NGX ->
#     {"success":true,"data":[{"ticker":...,"name":...,"exchange":"NGX",
#      "currency":"NGN",...}]}
# Two things that didn't match the pre-testing guess, worth flagging since a
# future provider written the same way would hit the same trap: the field is
# `name`, not `company_name` — and on the single-quote endpoint specifically,
# `currency` lives under the top-level `meta`, not inside `data` (the search
# endpoint's per-row `data` entries do carry their own `currency` directly).
class Provider::Mansa < Provider
  include SecurityConcept, RateLimitable
  extend SslConfigurable

  Error = Class.new(Provider::Error)
  InvalidSecurityPriceError = Class.new(Error)
  RateLimitError = Class.new(Error)

  # Mansa's docs specify a 100/day cap but don't document a per-minute pacing
  # limit the way TwelveData/EODHD do — this is a conservative default, not a
  # confirmed number, kept low to avoid tripping an undocumented limit.
  MIN_REQUEST_INTERVAL = 1.0

  MAX_REQUESTS_PER_DAY = 100

  # Historical data isn't available on the free tier (see class comment), so
  # there's no meaningful "how far back" answer here the way there is for
  # providers with real EOD history access.
  def max_history_days
    0
  end

  # Only NGX is confirmed working end-to-end (this is the exchange the fleet
  # actually needs). Mansa's API covers 21 African exchanges total — extend
  # this map once another one is actually verified against a live response,
  # rather than guessing MIC codes for exchanges nobody has tested here.
  MIC_TO_MANSA_EXCHANGE = {
    "XNSA" => "NGX"
  }.freeze

  MANSA_EXCHANGE_TO_MIC = MIC_TO_MANSA_EXCHANGE.invert.freeze

  def initialize(api_key)
    @api_key = api_key # pipelock:ignore
  end

  def healthy?
    with_provider_response do
      response = client.get("#{base_url}/api/v1/markets/exchanges/NGX/stocks") do |req|
        req.params["limit"] = 1
      end

      parsed = JSON.parse(response.body)
      parsed["success"] == true
    end
  end

  def usage
    with_provider_response do
      used = Rails.cache.read(daily_cache_key).to_i

      UsageData.new(
        used: used,
        limit: max_requests_per_day,
        utilization: used.to_f / max_requests_per_day * 100,
        plan: "free"
      )
    end
  end

  # ================================
  #           Securities
  # ================================

  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    with_provider_response do
      enforce_daily_limit!
      throttle_request

      mansa_exchange = MIC_TO_MANSA_EXCHANGE[exchange_operating_mic]

      response = client.get("#{base_url}/api/v1/markets/search") do |req|
        req.params["q"] = symbol
        req.params["exchange"] = mansa_exchange if mansa_exchange
        req.params["limit"] = 25
      end

      parsed = JSON.parse(response.body)
      check_api_error!(parsed)
      results = parsed.dig("data") || []

      results.map do |security|
        mic = MANSA_EXCHANGE_TO_MIC[security.dig("exchange")]

        Security.new(
          symbol: security.dig("ticker"),
          name: security.dig("name"),
          logo_url: nil,
          exchange_operating_mic: mic || security.dig("exchange"),
          country_code: nil,
          currency: security.dig("currency")
        )
      end
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    with_provider_response do
      quote = fetch_quote!(symbol:, exchange_operating_mic:)

      SecurityInfo.new(
        symbol: symbol,
        name: quote.dig("name"),
        links: nil,
        logo_url: nil,
        description: nil,
        kind: "stock",
        exchange_operating_mic: exchange_operating_mic
      )
    end
  end

  # Only returns a price for `date == Date.current` (or a date range that
  # includes today) — the free tier has no historical endpoint. See the
  # class comment and #fetch_security_prices.
  def fetch_security_price(symbol:, exchange_operating_mic: nil, date:)
    with_provider_response do
      unless date.to_date == Date.current
        raise InvalidSecurityPriceError,
          "Mansa's free tier only exposes the current quote, not a price for #{date} specifically. " \
          "Historical OHLCV requires a paid Mansa plan (see /history endpoint)."
      end

      quote = fetch_quote!(symbol:, exchange_operating_mic:)

      Price.new(
        symbol: symbol,
        date: Date.current,
        price: quote.dig("price"),
        currency: quote.dig("currency"),
        exchange_operating_mic: exchange_operating_mic
      )
    end
  end

  # Best-effort for a date range: if the range includes today, returns
  # today's live quote as a single-element array (better than nothing for a
  # "what's it worth right now" holding sync). A range that's entirely in the
  # past raises clearly rather than silently returning nothing, since that's
  # a real capability gap (Pro-tier /history), not a transient failure.
  def fetch_security_prices(symbol:, exchange_operating_mic: nil, start_date:, end_date:)
    with_provider_response do
      unless (start_date..end_date).cover?(Date.current)
        raise InvalidSecurityPriceError,
          "Mansa's free tier has no historical price endpoint (Pro plan required for /history). " \
          "Requested range #{start_date}..#{end_date} doesn't include today, so nothing can be returned."
      end

      quote = fetch_quote!(symbol:, exchange_operating_mic:)

      [
        Price.new(
          symbol: symbol,
          date: Date.current,
          price: quote.dig("price"),
          currency: quote.dig("currency"),
          exchange_operating_mic: exchange_operating_mic
        )
      ]
    end
  end

  private
    attr_reader :api_key

    def fetch_quote!(symbol:, exchange_operating_mic:)
      enforce_daily_limit!
      throttle_request

      mansa_exchange = MIC_TO_MANSA_EXCHANGE[exchange_operating_mic] || exchange_operating_mic

      response = client.get("#{base_url}/api/v1/markets/exchanges/#{mansa_exchange}/stocks/#{CGI.escape(symbol)}")

      parsed = JSON.parse(response.body)
      check_api_error!(parsed)
      quote = parsed.dig("data")

      raise InvalidSecurityPriceError, "No quote returned for #{symbol} on #{mansa_exchange}" if quote.blank?

      # Currency lives under the top-level `meta`, not inside `data`, on this
      # endpoint specifically (confirmed live — see class comment). Merge it
      # in so callers can keep reading `quote.dig("currency")` uniformly.
      quote.merge("currency" => parsed.dig("meta", "currency"))
    end

    def base_url
      ENV["MANSA_API_URL"] || "https://mansaapi.com"
    end

    def client
      @client ||= Faraday.new(url: base_url, ssl: self.class.faraday_ssl_options) do |faraday|
        faraday.request(:retry, {
          max: 3,
          interval: 1.0,
          interval_randomness: 0.5,
          backoff_factor: 2,
          exceptions: Faraday::Retry::Middleware::DEFAULT_EXCEPTIONS + [ Faraday::ConnectionFailed ]
        })

        faraday.request :json
        faraday.response :raise_error
        faraday.headers["Authorization"] = "Bearer #{api_key}"
      end
    end

    def daily_cache_key
      "mansa:daily:#{Date.current}"
    end

    def enforce_daily_limit!
      new_count = Rails.cache.increment(daily_cache_key, 1, expires_in: 24.hours).to_i

      if new_count > max_requests_per_day
        raise RateLimitError, "Mansa daily rate limit of #{max_requests_per_day} requests exhausted"
      end
    end

    def max_requests_per_day
      ENV.fetch("MANSA_MAX_REQUESTS_PER_DAY", MAX_REQUESTS_PER_DAY).to_i
    end

    # Confirmed live (2026-09-17): error responses nest a hash under "error"
    # ({"code","message","hint","docs"}), not a flat string — e.g.
    #   {"success":false,"error":{"code":"NOT_FOUND","message":"Ticker '...' not found on NGX.",...}}
    def check_api_error!(parsed)
      return unless parsed.is_a?(Hash) && parsed["success"] == false

      error = parsed["error"]
      message = error.is_a?(Hash) ? error["message"] : error
      code = error.is_a?(Hash) ? error["code"] : nil

      raise Error, "API error#{" (#{code})" if code}: #{message || "unknown error"}"
    end
end
