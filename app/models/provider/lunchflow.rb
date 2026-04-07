class Provider::Lunchflow
  include HTTParty
  extend SslConfigurable

  headers "User-Agent" => "Sure Finance Lunch Flow Client"
  default_options.merge!({ timeout: 120 }.merge(httparty_ssl_options))

  attr_reader :api_key, :base_url

  def initialize(api_key, base_url: "https://lunchflow.app/api/v1")
    @api_key = api_key
    @base_url = base_url
  end

  # Get all accounts
  # Returns: { accounts: [...], total: N }
  def get_accounts
    response = self.class.get(
      "#{@base_url}/accounts",
      headers: auth_headers
    )

    handle_response(response)
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "Lunch Flow API: GET /accounts failed: #{e.class}: #{e.message}"
    raise LunchflowError.new("Exception during GET request: #{e.message}", :request_failed)
  rescue => e
    Rails.logger.error "Lunch Flow API: Unexpected error during GET /accounts: #{e.class}: #{e.message}"
    raise LunchflowError.new("Exception during GET request: #{e.message}", :request_failed)
  end

  # Get transactions for a specific account
  # Returns: { transactions: [...], total: N }
  # Transaction structure: { id, accountId, amount, currency, date, merchant, description, isPending }
  def get_account_transactions(account_id, start_date: nil, end_date: nil, include_pending: false)
    query_params = {}

    if start_date
      query_params[:start_date] = start_date.to_date.to_s
    end

    if end_date
      query_params[:end_date] = end_date.to_date.to_s
    end

    if include_pending
      query_params[:include_pending] = true
    end

    path = "/accounts/#{ERB::Util.url_encode(account_id.to_s)}/transactions"
    path += "?#{URI.encode_www_form(query_params)}" unless query_params.empty?

    response = self.class.get(
      "#{@base_url}#{path}",
      headers: auth_headers
    )

    handle_response(response)
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "Lunch Flow API: GET #{path} failed: #{e.class}: #{e.message}"
    raise LunchflowError.new("Exception during GET request: #{e.message}", :request_failed)
  rescue => e
    Rails.logger.error "Lunch Flow API: Unexpected error during GET #{path}: #{e.class}: #{e.message}"
    raise LunchflowError.new("Exception during GET request: #{e.message}", :request_failed)
  end

  # Get balance for a specific account
  # Returns: { balance: { amount: N, currency: "USD" } }
  def get_account_balance(account_id)
    path = "/accounts/#{ERB::Util.url_encode(account_id.to_s)}/balance"

    response = self.class.get(
      "#{@base_url}#{path}",
      headers: auth_headers
    )

    handle_response(response)
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "Lunch Flow API: GET #{path} failed: #{e.class}: #{e.message}"
    raise LunchflowError.new("Exception during GET request: #{e.message}", :request_failed)
  rescue => e
    Rails.logger.error "Lunch Flow API: Unexpected error during GET #{path}: #{e.class}: #{e.message}"
    raise LunchflowError.new("Exception during GET request: #{e.message}", :request_failed)
  end

  # Get holdings for a specific account (investment accounts only)
  # Returns: { holdings: [...], totalValue: N, currency: "USD" }
  # Returns { holdings_not_supported: true } if API returns 501
  def get_account_holdings(account_id)
    path = "/accounts/#{ERB::Util.url_encode(account_id.to_s)}/holdings"

    response = self.class.get(
      "#{@base_url}#{path}",
      headers: auth_headers
    )

    # Handle 501 specially - indicates holdings not supported for this account
    if response.code == 501
      return { holdings_not_supported: true }
    end

    handle_response(response)
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "Lunch Flow API: GET #{path} failed: #{e.class}: #{e.message}"
    raise LunchflowError.new("Exception during GET request: #{e.message}", :request_failed)
  rescue => e
    Rails.logger.error "Lunch Flow API: Unexpected error during GET #{path}: #{e.class}: #{e.message}"
    raise LunchflowError.new("Exception during GET request: #{e.message}", :request_failed)
  end

  private

    def auth_headers
      {
        "x-api-key" => api_key,
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }
    end

    def handle_response(response)
      case response.code
      when 200
        JSON.parse(response.body, symbolize_names: true)
      when 400
        Rails.logger.error "Lunch Flow API: Bad request - #{response.body}"
        raise LunchflowError.new("Bad request to Lunch Flow API: #{response.body}", :bad_request)
      when 401
        raise LunchflowError.new("Invalid API key", :unauthorized)
      when 403
        raise LunchflowError.new("Access forbidden - check your API key permissions", :access_forbidden)
      when 404
        raise LunchflowError.new("Resource not found", :not_found)
      when 429
        raise LunchflowError.new("Rate limit exceeded. Please try again later.", :rate_limited)
      else
        Rails.logger.error "Lunch Flow API: Unexpected response - Code: #{response.code}, Body: #{response.body}"
        raise LunchflowError.new("Failed to fetch data: #{response.code} #{response.message} - #{response.body}", :fetch_failed)
      end
    end

    class LunchflowError < StandardError
      attr_reader :error_type

      def initialize(message, error_type = :unknown)
        super(message)
        @error_type = error_type
      end
    end
end
