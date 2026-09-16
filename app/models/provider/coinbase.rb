class Provider::Coinbase
  include HTTParty
  extend SslConfigurable

  class Error < StandardError; end
  class AuthenticationError < Error; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  # CDP API base URL
  API_BASE_URL = "https://api.coinbase.com".freeze

  base_uri API_BASE_URL
  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  attr_reader :api_key, :api_secret

  def initialize(api_key:, api_secret:)
    @api_key = api_key
    @api_secret = api_secret
  end

  # Get current user info
  def get_user
    get("/v2/user")["data"]
  end

  # Get all accounts (wallets)
  def get_accounts
    paginated_get("/v2/accounts")
  end

  # Get single account details
  def get_account(account_id)
    get("/v2/accounts/#{account_id}")["data"]
  end

  # Get transactions for an account
  def get_transactions(account_id, limit: 100)
    paginated_get("/v2/accounts/#{account_id}/transactions", limit: limit)
  end

  # Get buy transactions for an account
  def get_buys(account_id, limit: 100)
    paginated_get("/v2/accounts/#{account_id}/buys", limit: limit)
  end

  # Get sell transactions for an account
  def get_sells(account_id, limit: 100)
    paginated_get("/v2/accounts/#{account_id}/sells", limit: limit)
  end

  # Get deposits for an account
  def get_deposits(account_id, limit: 100)
    paginated_get("/v2/accounts/#{account_id}/deposits", limit: limit)
  end

  # Get withdrawals for an account
  def get_withdrawals(account_id, limit: 100)
    paginated_get("/v2/accounts/#{account_id}/withdrawals", limit: limit)
  end

  # Get spot price for a currency pair (e.g., "BTC-USD")
  # This is a public endpoint that doesn't require authentication
  def get_spot_price(currency_pair)
    # Use self.class.get to inherit class-level SSL and timeout defaults
    response = self.class.get("/v2/prices/#{currency_pair}/spot", timeout: 10)
    handle_response(response)["data"]
  rescue => e
    Rails.logger.warn("Coinbase: Failed to fetch spot price for #{currency_pair}: #{e.message}")
    nil
  end

  # Get spot prices for multiple currencies in USD
  # Returns hash like { "BTC" => 92520.90, "ETH" => 3200.50 }
  def get_spot_prices(currencies)
    prices = {}
    currencies.each do |currency|
      result = get_spot_price("#{currency}-USD")
      prices[currency] = result["amount"].to_d if result && result["amount"]
    end
    prices
  end

  # Shared ingestion consumes one exact response at a time. The legacy helpers
  # above retain their existing limits and behavior during incremental rollout.
  def get_accounts_page(cursor: nil)
    ingestion_collection("/v2/accounts", cursor: cursor)
  end

  def get_account_page(account_id)
    ingestion_object("/v2/accounts/#{ingestion_identifier(account_id)}")
  end

  def get_transactions_page(account_id, cursor: nil)
    ingestion_collection("/v2/accounts/#{ingestion_identifier(account_id)}/transactions", cursor: cursor)
  end

  def get_buys_page(account_id, cursor: nil)
    ingestion_collection("/v2/accounts/#{ingestion_identifier(account_id)}/buys", cursor: cursor)
  end

  def get_sells_page(account_id, cursor: nil)
    ingestion_collection("/v2/accounts/#{ingestion_identifier(account_id)}/sells", cursor: cursor)
  end

  def get_spot_price_page(currency_pair)
    ingestion_object("/v2/prices/#{ingestion_identifier(currency_pair)}/spot", authenticated: false)
  end

  private

    def ingestion_identifier(value)
      unless value.is_a?(String) && value.match?(/\A[A-Za-z0-9_:-]+\z/)
        raise ApiError, "Invalid Coinbase resource identifier"
      end
      value
    end

    def ingestion_path(path, cursor)
      return "#{path}?limit=100" if cursor.nil?
      raise ArgumentError unless cursor.is_a?(String) && cursor.present?
      uri = URI.parse(cursor)
      unless uri.scheme.nil? && uri.host.nil? && uri.userinfo.nil? && uri.fragment.nil? && uri.path == path
        raise ArgumentError
      end
      cursor
    rescue ArgumentError, URI::InvalidURIError
      raise ApiError, "Invalid Coinbase continuation", cause: nil
    end

    def ingestion_collection(path, cursor:)
      data = ingestion_get(ingestion_path(path, cursor))
      rows = data["data"]
      pagination = data["pagination"]
      unless rows.is_a?(Array) && rows.size <= 100 && rows.all? { |row| row.is_a?(Hash) } &&
          pagination.is_a?(Hash) && pagination.key?("next_uri")
        raise ApiError, "Invalid Coinbase collection"
      end
      continuation = pagination["next_uri"]
      ingestion_path(path, continuation) unless continuation.nil?
      { items: rows, next_cursor: continuation, evidence: data }
    end

    def ingestion_object(path, authenticated: true)
      data = ingestion_get(path, authenticated: authenticated)
      raise ApiError, "Invalid Coinbase resource" unless data["data"].is_a?(Hash)
      { items: [ data["data"] ], next_cursor: nil, evidence: data }
    end

    def ingestion_get(path, authenticated: true)
      options = authenticated ? { headers: auth_headers("GET", path.split("?").first) } : { timeout: 10 }
      response = self.class.get(path, **options)
      case response.code
      when 200..299
        parsed = JSON.parse(response.body, decimal_class: BigDecimal)
        raise ApiError, "Invalid Coinbase response" unless parsed.is_a?(Hash)
        parsed
      when 401, 403
        raise AuthenticationError, "Coinbase authorization does not permit this resource"
      when 429
        raise RateLimitError, "Coinbase request was rate limited"
      else
        raise ApiError, "Coinbase request failed (HTTP #{response.code})"
      end
    rescue JSON::ParserError, TypeError
      raise ApiError, "Invalid Coinbase response", cause: nil
    end

    def get(path, params: {})
      url = path
      url += "?#{params.to_query}" if params.any?

      # Use self.class.get to inherit class-level SSL and timeout defaults
      response = self.class.get(
        url,
        headers: auth_headers("GET", path)
      )

      handle_response(response)
    end

    def paginated_get(path, limit: 100)
      results = []
      next_uri = nil
      fetched = 0

      loop do
        if next_uri
          # Parse the next_uri to get just the path
          uri = URI.parse(next_uri)
          current_path = uri.path
          current_path += "?#{uri.query}" if uri.query
        else
          current_path = path
        end

        # Use self.class.get to inherit class-level SSL and timeout defaults
        response = self.class.get(
          current_path,
          headers: auth_headers("GET", current_path.split("?").first)
        )

        data = handle_response(response)
        results.concat(data["data"] || [])
        fetched += (data["data"] || []).size

        break if fetched >= limit
        break unless data.dig("pagination", "next_uri")

        next_uri = data.dig("pagination", "next_uri")
      end

      results.first(limit)
    end

    # Parses a PEM EC private key, normalizing literal \n sequences to real
    # newlines. Coinbase CDP keys are often stored or pasted as a single-line
    # string with escaped newlines (e.g. copied directly from the JSON download
    # file). Both forms are accepted.
    def parse_ec_private_key(pem)
      OpenSSL::PKey::EC.new(pem.to_s.gsub('\n', "\n"))
    end

    # Generate JWT token for CDP API authentication.
    # Uses ES256 (ECDSA P-256) signing — matches the key format Coinbase CDP
    # issues. api_secret must be a PEM EC private key
    # (-----BEGIN EC PRIVATE KEY-----) either with real newlines or literal \n.
    def generate_jwt(method, path)
      private_key = parse_ec_private_key(api_secret)

      now = Time.now.to_i
      uri = "#{method} api.coinbase.com#{path}"

      # JWT header
      header = {
        alg: "ES256",
        kid: api_key,
        nonce: SecureRandom.hex(16),
        typ: "JWT"
      }

      # JWT payload
      payload = {
        sub: api_key,
        iss: "cdp",
        nbf: now,
        exp: now + 120,
        uri: uri
      }

      # Encode header and payload
      encoded_header = Base64.urlsafe_encode64(header.to_json, padding: false)
      encoded_payload = Base64.urlsafe_encode64(payload.to_json, padding: false)

      # Sign with ECDSA SHA-256
      message = "#{encoded_header}.#{encoded_payload}"
      der_sig = private_key.sign(OpenSSL::Digest::SHA256.new, message)

      # Convert DER-encoded signature to raw r||s (required by JWT spec)
      asn1 = OpenSSL::ASN1.decode(der_sig)
      r = asn1.value[0].value.to_s(2).rjust(32, "\x00")[-32..]
      s = asn1.value[1].value.to_s(2).rjust(32, "\x00")[-32..]
      encoded_signature = Base64.urlsafe_encode64(r + s, padding: false)

      "#{message}.#{encoded_signature}"
    end

    def auth_headers(method, path)
      {
        "Authorization" => "Bearer #{generate_jwt(method, path)}",
        "Content-Type" => "application/json"
      }
    end

    def handle_response(response)
      parsed = response.parsed_response

      case response.code
      when 200..299
        parsed.is_a?(Hash) ? parsed : { "data" => parsed }
      when 401
        error_msg = extract_error_message(parsed) || "Unauthorized - check your API key and secret"
        raise AuthenticationError, error_msg
      when 429
        raise RateLimitError, "Rate limit exceeded"
      else
        error_msg = extract_error_message(parsed) || "API error: #{response.code}"
        raise ApiError, error_msg
      end
    end

    def extract_error_message(parsed)
      return parsed if parsed.is_a?(String)
      return nil unless parsed.is_a?(Hash)

      parsed.dig("errors", 0, "message") || parsed["error"] || parsed["message"]
    end
end
