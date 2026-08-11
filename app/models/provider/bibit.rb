# Securities provider for Indonesian reksadana (mutual funds) via the Bibit API.
#
# Bibit (bibit.id) is the largest reksadana distribution platform in Indonesia
# with 2,937+ funds. The public API provides fund search, details, and historical
# daily NAV data without requiring an API key.
#
# API responses are AES-256-CBC encrypted. The encryption scheme packs the IV
# (first 32 hex chars), hex-encoded ciphertext (middle), and key (last 32 UTF-8
# chars) into a single string. Decryption uses Ruby's built-in OpenSSL::Cipher.
#
# Securities are returned with exchange_operating_mic "XIDX" (Indonesia Stock
# Exchange) and currency "IDR".
class Provider::Bibit < Provider
  include SecurityConcept, RateLimitable
  extend SslConfigurable

  Error = Class.new(Provider::Error)
  InvalidSecurityPriceError = Class.new(Error)
  RateLimitError = Class.new(Error)
  DecryptionError = Class.new(Error)

  # Minimum delay between requests
  MIN_REQUEST_INTERVAL = 0.5

  def initialize
    # No API key required — Bibit public endpoints are keyless
  end

  # Checks connectivity by fetching fund RD66 (Avrist Ada Kas Mutiara).
  def healthy?
    with_provider_response do
      data = fetch_and_decrypt("#{base_url}/products/RD66")
      data["symbol"] == "RD66"
    end
  end

  # Returns static usage info — Bibit is free and keyless.
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

  # Searches reksadana funds by name via Bibit's /products/list endpoint.
  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    with_provider_response do
      throttle_request
      data = fetch_and_decrypt("#{base_url}/products/list") do |req|
        req.params["name"] = symbol
        req.params["page"] = 1
        req.params["limit"] = 25
        req.params["sort"] = "asc"
        req.params["sort_by"] = 7 # sort by name
      end

      funds = data.is_a?(Array) ? data : (data["data"] || [])

      funds.first(25).map do |fund|
        Security.new(
          symbol: fund["symbol"].to_s,
          name: fund["name"],
          logo_url: nil,
          exchange_operating_mic: "XIDX",
          country_code: "ID",
          currency: "IDR"
        )
      end
    end
  end

  # Fetches fund detail (name, manager, type) via /products/{symbol}.
  def fetch_security_info(symbol:, exchange_operating_mic:)
    with_provider_response do
      throttle_request
      data = fetch_and_decrypt("#{base_url}/products/#{CGI.escape(symbol)}")

      manager = data["investment_manager"] || {}
      custodian = data["custodian_bank"] || {}

      SecurityInfo.new(
        symbol: symbol,
        name: data["name"],
        links: nil,
        logo_url: nil,
        description: [ manager["name"], data["type"] ].compact.join(" — "),
        kind: "mutual fund",
        exchange_operating_mic: exchange_operating_mic
      )
    end
  end

  # Fetches the NAV for a single date by querying a short historical window.
  def fetch_security_price(symbol:, exchange_operating_mic: nil, date:)
    with_provider_response do
      historical_data = fetch_security_prices(symbol:, exchange_operating_mic:, start_date: date - 7.days, end_date: date)

      raise historical_data.error if historical_data.error.present?
      raise InvalidSecurityPriceError, "No NAV found for fund #{symbol} on or before #{date}" if historical_data.data.blank?

      # Find exact date or closest previous
      historical_data.data.select { |p| p.date <= date }.max_by(&:date) || historical_data.data.first
    end
  end

  # Fetches historical daily NAV data via /products/{symbol}/chart.
  # Bibit chart periods are trailing windows from today; the smallest
  # period that covers +start_date+ through today is chosen automatically.
  def fetch_security_prices(symbol:, exchange_operating_mic: nil, start_date:, end_date:)
    with_provider_response do
      throttle_request
      # Bibit chart endpoint returns daily NAV data for a given period
      # We use 'all' to get the full history and filter client-side,
      # since Bibit doesn't support arbitrary date ranges
      period = select_period(start_date, end_date)

      data = fetch_and_decrypt("#{base_url}/products/#{CGI.escape(symbol)}/chart") do |req|
        req.params["period"] = period
      end

      chart_data = data.is_a?(Hash) ? (data["chart"] || []) : data

      if chart_data.nil? || !chart_data.is_a?(Array)
        raise InvalidSecurityPriceError, "No NAV data returned for fund #{symbol}"
      end

      chart_data.filter_map do |entry|
        nav = entry["value"]
        date_str = entry["formated_date"]

        next if nav.nil? || nav.to_f <= 0 || date_str.blank?

        date = Date.parse(date_str)
        next if date < start_date || date > end_date

        Price.new(
          symbol: symbol,
          date: date,
          price: nav.to_f,
          currency: "IDR",
          exchange_operating_mic: exchange_operating_mic
        )
      end.sort_by(&:date)
    end
  end

  private

    # Base URL for the Bibit API. Override with BIBIT_URL env var.
    def base_url
      ENV["BIBIT_URL"] || "https://api.bibit.id"
    end

    # Selects the smallest Bibit chart period that covers the requested date range.
    #
    # Bibit chart periods are trailing windows from today (e.g. "1m" returns the
    # last 30 days). We must measure from +start_date+ to today — not just the
    # span of the requested range — otherwise a historical request (e.g. July
    # 10-14 made on August 11) would pick "1w" but the API would return the
    # recent week instead of data from July.
    def select_period(start_date, _end_date)
      days = (Date.current - start_date).to_i

      if days <= 7
        "1w"
      elsif days <= 30
        "1m"
      elsif days <= 90
        "3m"
      elsif days <= 365
        "1y"
      elsif days <= 3 * 365
        "3y"
      elsif days <= 5 * 365
        "5y"
      else
        "all"
      end
    end

    # HTTP client with retry, JSON encoding, and required Origin/Referer headers.
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
        faraday.headers["Origin"] = "https://bibit.id"
        faraday.headers["Referer"] = "https://bibit.id/"

        faraday.options.timeout = 10
        faraday.options.open_timeout = 5
      end
    end

    # Fetches a URL and decrypts the AES-CBC encrypted response.
    # Bibit wraps all API responses in: { "message": "...", "data": "<encrypted>" }
    # Encryption scheme: IV (first 32 hex chars) + ciphertext (hex) + key (last 32 UTF-8 chars)
    def fetch_and_decrypt(url)
      response = client.get(url) do |req|
        yield req if block_given?
      end

      parsed = JSON.parse(response.body)

      unless parsed["data"].is_a?(String) && parsed["data"].length > 64
        raise Error, "Unexpected response format from Bibit API"
      end

      decrypt(parsed["data"])
    rescue JSON::ParserError => e
      raise Error, "Invalid response format: #{e.message}"
    end

    # Decrypts a Bibit AES-256-CBC encrypted payload.
    # Format: IV (32 hex chars) + ciphertext (hex) + key (32 UTF-8 chars).
    def decrypt(encrypted_data)
      iv_hex = encrypted_data[0, 32]
      key_utf8 = encrypted_data[-32, 32]
      ciphertext_hex = encrypted_data[32...-32]

      iv = [ iv_hex ].pack("H*")
      key = key_utf8.encode("UTF-8")
      ciphertext = [ ciphertext_hex ].pack("H*")

      cipher = OpenSSL::Cipher::AES.new(256, :CBC)
      cipher.decrypt
      cipher.iv = iv
      cipher.key = key

      plaintext = cipher.update(ciphertext) + cipher.final
      JSON.parse(plaintext)
    rescue OpenSSL::Cipher::CipherError => e
      raise DecryptionError, "Failed to decrypt Bibit response: #{e.message}"
    rescue JSON::ParserError => e
      raise DecryptionError, "Decrypted data is not valid JSON: #{e.message}"
    end
end
