class Provider::Mfapi < Provider::Base
  extend SslConfigurable

  Error = Class.new(Provider::Error)
  InvalidSchemeError = Class.new(Error)
  RateLimitError = Class.new(Error)

  CACHE_DURATION = 15.minutes

  def provider_name
    "mfapi"
  end

  def healthy?
    fetch_latest_nav("118532") # HDFC Mid-Cap Opportunities Fund - reliable test case
    true
  rescue
    false
  end

  def search_schemes(query)
    cache_key = "search_schemes_#{query.downcase.gsub(/\s+/, '_')}"
    cached = get_cached_result(cache_key)
    return cached if cached.present?

    response = client.get("#{base_url}/mf/search") do |req|
      req.params["q"] = query
    end

    schemes = JSON.parse(response.body)

    results = schemes.first(25).map do |scheme|
      Scheme.new(
        scheme_code: scheme["scheme_code"],
        amfi_code: scheme["amc_code"],
        name: scheme["scheme_name"],
        scheme_type: scheme["scheme_type"],
        fund_house: scheme["mutual_fund"]
      )
    end

    cache_result(cache_key, results)
    results
  end

  def fetch_latest_nav(scheme_code)
    cache_key = "latest_nav_#{scheme_code}"
    cached = get_cached_result(cache_key)
    return cached if cached.present?

    response = client.get("#{base_url}/mf/#{scheme_code}/latest")
    data = JSON.parse(response.body)

    raise InvalidSchemeError, "Invalid scheme code: #{scheme_code}" if data["status"] == "false"

    meta = data["meta"] || {}
    nav_data = data["data"]&.first || {}

    NavData.new(
      scheme_code: scheme_code,
      scheme_name: meta["scheme_name"],
      nav: nav_data["nav"].to_f,
      date: nav_data["date"],
      change: nav_data["change"].to_f,
      change_percent: nav_data["change_percent"].to_f,
      fund_house: meta["fund_house"],
      scheme_type: meta["scheme_type"],
      category: meta["scheme_category"]
    )
  end

  def fetch_nav_history(scheme_code, start_date: nil, end_date: nil)
    end_date ||= Date.current
    start_date ||= end_date - 1.year

    cache_key = "nav_history_#{scheme_code}_#{start_date}_#{end_date}"
    cached = get_cached_result(cache_key)
    return cached if cached.present?

    response = client.get("#{base_url}/mf/#{scheme_code}") do |req|
      req.params["from"] = start_date.to_s
      req.params["to"] = end_date.to_s
    end

    data = JSON.parse(response.body)

    raise InvalidSchemeError, "Invalid scheme code: #{scheme_code}" if data["status"] == "false"

    prices = (data["data"] || []).map do |nav_record|
      Price.new(
        scheme_code: scheme_code,
        date: nav_record["date"],
        nav: nav_record["nav"].to_f
      )
    end.compact

    cache_result(cache_key, prices)
    prices
  end

  def fetch_scheme_info(scheme_code)
    cache_key = "scheme_info_#{scheme_code}"
    cached = get_cached_result(cache_key)
    return cached if cached.present?

    latest_nav = fetch_latest_nav(scheme_code)

    SchemeInfo.new(
      scheme_code: scheme_code,
      name: latest_nav.scheme_name,
      fund_house: latest_nav.fund_house,
      scheme_type: latest_nav.scheme_type,
      category: latest_nav.category,
      current_nav: latest_nav.nav,
      nav_date: latest_nav.date
    )
  end

  def to_security(scheme_code)
    info = fetch_scheme_info(scheme_code)

    Security.new(
      symbol: scheme_code,
      name: info.name,
      logo_url: nil,
      exchange_operating_mic: "XINDX", # India Exchange (NSE/BSE) MIC for MFs
      country_code: "IN"
    )
  end

  def to_price(scheme_code, date: nil)
    date ||= Date.current
    nav_data = fetch_latest_nav(scheme_code)

    Price.new(
      symbol: scheme_code,
      date: date,
      price: nav_data.nav,
      currency: "INR",
      exchange_operating_mic: "XINDX"
    )
  end

  private

    def base_url
      ENV.fetch("MFAPI_URL", "https://api.mfapi.in")
    end

    def client
      @client ||= Faraday.new(url: base_url, ssl: self.class.faraday_ssl_options) do |faraday|
        faraday.request(:retry, {
          max: 3,
          interval: 1.0,
          interval_randomness: 0.5,
          backoff_factor: 2,
          retry_statuses: [ 429 ],
          exceptions: [ Faraday::ConnectionFailed, Faraday::TimeoutError ]
        })

        faraday.request :json
        faraday.response :raise_error
        faraday.headers["Accept"] = "application/json"
        faraday.options.timeout = 30
        faraday.options.open_timeout = 10
      end
    end

    def get_cached_result(key)
      full_key = "mfapi_#{key}"
      Rails.cache.read(full_key)
    end

    def cache_result(key, data)
      full_key = "mfapi_#{key}"
      Rails.cache.write(full_key, data, expires_in: CACHE_DURATION)
    end

    def default_error_transformer(error)
      case error
      when Faraday::TooManyRequestsError
        RateLimitError.new("MFAPI rate limit exceeded", details: error.response&.dig(:body))
      when Faraday::Error
        Error.new(error.message, details: error.response&.dig(:body))
      else
        Error.new(error.message)
      end
    end

    Data.define(:Scheme, :scheme_code, :amfi_code, :name, :scheme_type, :fund_house)
    Data.define(:NavData, :scheme_code, :scheme_name, :nav, :date, :change, :change_percent, :fund_house, :scheme_type, :category)
    Data.define(:Price, :symbol, :date, :nav, :currency, :exchange_operating_mic)
    Data.define(:SchemeInfo, :scheme_code, :name, :fund_house, :scheme_type, :category, :current_nav, :nav_date)
    Data.define(:Security, :symbol, :name, :logo_url, :exchange_operating_mic, :country_code)
end
