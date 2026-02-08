class Provider::Mercury
  include HTTParty
  extend SslConfigurable

  headers "User-Agent" => "Sure Finance Mercury Client"
  default_options.merge!({ timeout: 120 }.merge(httparty_ssl_options))

  attr_reader :token, :base_url

  def initialize(token, base_url: "https://api.mercury.com/api/v1")
    @token = token
    @base_url = base_url
  end

  # Get all accounts
  # Returns: { accounts: [...] }
  # Account structure: { id, name, currentBalance, availableBalance, status, type, kind, legalBusinessName, nickname }
  def get_accounts
    response = self.class.get(
      "#{@base_url}/accounts",
      headers: auth_headers
    )

    handle_response(response)
  rescue MercuryError
    raise
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "Mercury API: GET /accounts failed: #{e.class}: #{e.message}"
    raise MercuryError.new("Exception during GET request: #{e.message}", :request_failed)
  rescue => e
    Rails.logger.error "Mercury API: Unexpected error during GET /accounts: #{e.class}: #{e.message}"
    raise MercuryError.new("Exception during GET request: #{e.message}", :request_failed)
  end

  # Get a single account by ID
  # Returns: { id, name, currentBalance, availableBalance, status, type, kind, ... }
  def get_account(account_id)
    path = "/account/#{ERB::Util.url_encode(account_id.to_s)}"

    response = self.class.get(
      "#{@base_url}#{path}",
      headers: auth_headers
    )

    handle_response(response)
  rescue MercuryError
    raise
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "Mercury API: GET #{path} failed: #{e.class}: #{e.message}"
    raise MercuryError.new("Exception during GET request: #{e.message}", :request_failed)
  rescue => e
    Rails.logger.error "Mercury API: Unexpected error during GET #{path}: #{e.class}: #{e.message}"
    raise MercuryError.new("Exception during GET request: #{e.message}", :request_failed)
  end

  # Get transactions for a specific account
  # Returns: { transactions: [...], total: N }
  # Transaction structure: { id, amount, bankDescription, counterpartyId, counterpartyName,
  #                          counterpartyNickname, createdAt, dashboardLink, details,
  #                          estimatedDeliveryDate, failedAt, kind, note, postedAt,
  #                          reasonForFailure, status }
  def get_account_transactions(account_id, start_date: nil, end_date: nil, offset: nil, limit: nil)
    query_params = {}

    if start_date
      query_params[:start] = start_date.to_date.to_s
    end

    if end_date
      query_params[:end] = end_date.to_date.to_s
    end

    if offset
      query_params[:offset] = offset.to_i
    end

    if limit
      query_params[:limit] = limit.to_i
    end

    path = "/account/#{ERB::Util.url_encode(account_id.to_s)}/transactions"
    path += "?#{URI.encode_www_form(query_params)}" unless query_params.empty?

    response = self.class.get(
      "#{@base_url}#{path}",
      headers: auth_headers
    )

    handle_response(response)
  rescue MercuryError
    raise
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "Mercury API: GET #{path} failed: #{e.class}: #{e.message}"
    raise MercuryError.new("Exception during GET request: #{e.message}", :request_failed)
  rescue => e
    Rails.logger.error "Mercury API: Unexpected error during GET #{path}: #{e.class}: #{e.message}"
    raise MercuryError.new("Exception during GET request: #{e.message}", :request_failed)
  end

  private

    def auth_headers
      {
        "Authorization" => "Bearer #{token}",
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }
    end

    def handle_response(response)
      case response.code
      when 200
        JSON.parse(response.body, symbolize_names: true)
      when 400
        Rails.logger.error "Mercury API: Bad request - #{response.body}"
        raise MercuryError.new("Bad request to Mercury API: #{response.body}", :bad_request)
      when 401
        # Parse the error response for more specific messages
        error_message = parse_error_message(response.body)
        raise MercuryError.new(error_message, :unauthorized)
      when 403
        raise MercuryError.new("Access forbidden - check your API token permissions", :access_forbidden)
      when 404
        raise MercuryError.new("Resource not found", :not_found)
      when 429
        raise MercuryError.new("Rate limit exceeded. Please try again later.", :rate_limited)
      else
        Rails.logger.error "Mercury API: Unexpected response - Code: #{response.code}, Body: #{response.body}"
        raise MercuryError.new("Failed to fetch data: #{response.code} #{response.message} - #{response.body}", :fetch_failed)
      end
    end

    def parse_error_message(body)
      parsed = JSON.parse(body, symbolize_names: true)
      errors = parsed[:errors] || {}

      case errors[:errorCode]
      when "ipNotWhitelisted"
        ip = errors[:ip] || "unknown"
        "IP address not whitelisted (#{ip}). Add your IP to the API token's whitelist in Mercury dashboard."
      when "noTokenInDBButMaybeMalformed"
        "Invalid token format. Make sure to include the 'secret-token:' prefix."
      else
        errors[:message] || "Invalid API token"
      end
    rescue JSON::ParserError
      "Invalid API token"
    end

    class MercuryError < StandardError
      attr_reader :error_type

      def initialize(message, error_type = :unknown)
        super(message)
        @error_type = error_type
      end
    end
end
