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

  private

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

    # Generate JWT token for CDP API authentication
    # Uses Ed25519 signing algorithm
    def generate_jwt(method, path)
      # Decode the base64 private key
      private_key_bytes = Base64.decode64(api_secret)

      # Create Ed25519 signing key
      signing_key = Ed25519::SigningKey.new(private_key_bytes[0, 32])

      now = Time.now.to_i
      uri = "#{method} api.coinbase.com#{path}"

      # JWT header
      header = {
        alg: "EdDSA",
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

      # Sign
      message = "#{encoded_header}.#{encoded_payload}"
      signature = signing_key.sign(message)
      encoded_signature = Base64.urlsafe_encode64(signature, padding: false)

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
