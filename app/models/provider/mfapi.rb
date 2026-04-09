class Provider::Mfapi < Provider
  include SecurityConcept, RateLimitable
  extend SslConfigurable

  Error = Class.new(Provider::Error)
  InvalidSecurityPriceError = Class.new(Error)
  RateLimitError = Class.new(Error)

  # Minimum delay between requests
  MIN_REQUEST_INTERVAL = 0.5

  def initialize
    # No API key required
  end

  def healthy?
    with_provider_response do
      response = client.get("#{base_url}/mf/125497/latest")
      parsed = JSON.parse(response.body)
      parsed.dig("meta", "scheme_name").present?
    end
  end

  def usage
    with_provider_response do
      UsageData.new(
        used: nil,
        limit: nil,
        utilization: nil,
        plan: "Free (no key required)"
      )
    end
  end

  # ================================
  #           Securities
  # ================================

  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    with_provider_response do
      throttle_request
      response = client.get("#{base_url}/mf/search") do |req|
        req.params["q"] = symbol
      end

      parsed = JSON.parse(response.body)
      check_api_error!(parsed)

      unless parsed.is_a?(Array)
        raise Error, "Unexpected response format from search endpoint"
      end

      parsed.first(25).map do |fund|
        Security.new(
          symbol: fund["schemeCode"].to_s,
          name: fund["schemeName"],
          logo_url: nil,
          exchange_operating_mic: "XBOM",
          country_code: "IN",
          currency: "INR"
        )
      end
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    with_provider_response do
      throttle_request
      response = client.get("#{base_url}/mf/#{CGI.escape(symbol)}/latest")

      parsed = JSON.parse(response.body)
      check_api_error!(parsed)

      meta = parsed["meta"] || {}

      SecurityInfo.new(
        symbol: symbol,
        name: meta["scheme_name"],
        links: nil,
        logo_url: nil,
        description: [ meta["fund_house"], meta["scheme_category"] ].compact.join(" - "),
        kind: "mutual fund",
        exchange_operating_mic: exchange_operating_mic
      )
    end
  end

  def fetch_security_price(symbol:, exchange_operating_mic: nil, date:)
    with_provider_response do
      historical_data = fetch_security_prices(symbol:, exchange_operating_mic:, start_date: date - 7.days, end_date: date)

      raise historical_data.error if historical_data.error.present?
      raise InvalidSecurityPriceError, "No NAV found for scheme #{symbol} on or before #{date}" if historical_data.data.blank?

      # Find exact date or closest previous
      historical_data.data.select { |p| p.date <= date }.max_by(&:date) || historical_data.data.first
    end
  end

  def fetch_security_prices(symbol:, exchange_operating_mic: nil, start_date:, end_date:)
    with_provider_response do
      throttle_request
      response = client.get("#{base_url}/mf/#{CGI.escape(symbol)}") do |req|
        req.params["startDate"] = start_date.to_s
        req.params["endDate"] = end_date.to_s
      end

      parsed = JSON.parse(response.body)
      check_api_error!(parsed)

      nav_data = parsed["data"]

      if nav_data.nil? || !nav_data.is_a?(Array)
        raise InvalidSecurityPriceError, "No NAV data returned for scheme #{symbol}"
      end

      nav_data.filter_map do |entry|
        nav = entry["nav"]
        date_str = entry["date"]

        next if nav.nil? || nav.to_f <= 0 || date_str.blank?

        # MFAPI returns dates as DD-MM-YYYY
        date = Date.strptime(date_str, "%d-%m-%Y")

        Price.new(
          symbol: symbol,
          date: date,
          price: nav.to_f,
          currency: "INR",
          exchange_operating_mic: exchange_operating_mic
        )
      end
    end
  end

  private

    def base_url
      ENV["MFAPI_URL"] || "https://api.mfapi.in"
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
        faraday.headers["Accept"] = "application/json"
      end
    end

    # throttle_request and min_request_interval provided by RateLimitable

    def check_api_error!(parsed)
      return unless parsed.is_a?(Hash)

      if parsed["status"] == "ERROR" || parsed["status"] == "FAIL"
        raise Error, "API error: #{parsed['message'] || parsed['status']}"
      end
    end
end
