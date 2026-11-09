class Provider::Sharesight
  include HTTParty
  extend SslConfigurable

  class Error < StandardError; end
  class AuthenticationError < Error; end
  class ConfigurationError < Error; end
  class RateLimitError < Error; end
  class ApiError < Error
    attr_reader :status_code, :response_body

    def initialize(message, status_code: nil, response_body: nil)
      super(message)
      @status_code = status_code
      @response_body = response_body
    end
  end

  BASE_URI = "https://api.sharesight.com".freeze
  USER_AGENT = "Sure Finance Sharesight Client".freeze

  RETRYABLE_ERRORS = [
    SocketError,
    Net::OpenTimeout,
    Net::ReadTimeout,
    Errno::ECONNRESET,
    Errno::ECONNREFUSED,
    Errno::ETIMEDOUT,
    EOFError
  ].freeze

  default_options.merge!({ timeout: 60 }.merge(httparty_ssl_options))

  attr_reader :client_id, :client_secret

  # Sharesight hands out API clients on request. We swap the id and secret for
  # a 30 minute token (client_credentials), so there's no refresh token to keep.
  def initialize(client_id:, client_secret:)
    raise ConfigurationError, "client_id is required" if client_id.blank?
    raise ConfigurationError, "client_secret is required" if client_secret.blank?

    @client_id = client_id.to_s.strip
    @client_secret = client_secret.to_s.strip
  end

  def fetch_portfolios
    Array(get("/api/v2/portfolios.json")["portfolios"])
  end

  # Holdings (with each instrument's currency and price), cash accounts and the
  # total value. Sold holdings are included so we can still find every trade's
  # holding.
  def fetch_performance(portfolio_id)
    get("/api/v3/portfolios/#{portfolio_id}/performance", query: { include_sales: true })["report"] || {}
  end

  def fetch_trades(portfolio_id)
    Array(get("/api/v2/portfolios/#{portfolio_id}/trades.json")["trades"])
  end

  def fetch_payouts(portfolio_id, start_date:, end_date: Date.current)
    query = { start_date: start_date.iso8601, end_date: end_date.iso8601 }
    Array(get("/api/v2/portfolios/#{portfolio_id}/payouts.json", query: query)["payouts"])
  end

  def fetch_cash_accounts
    Array(get("/api/v2/cash_accounts.json")["cash_accounts"])
  end

  def fetch_cash_account_transactions(cash_account_id)
    Array(get("/api/v2/cash_accounts/#{cash_account_id}/cash_account_transactions.json")["cash_account_transactions"])
  end

  private

    def get(path, query: {})
      response = request(path, query)

      # A long sync can outlast the 30 minute token, so get a new one and retry once.
      if response.code == 401
        @access_token = nil
        response = request(path, query)
      end

      handle_response(response)
    end

    def request(path, query)
      with_retries(path) do
        self.class.get("#{BASE_URI}#{path}", headers: auth_headers, query: query.compact)
      end
    end

    def auth_headers
      {
        "Authorization" => "Bearer #{access_token}",
        "Accept" => "application/json",
        "User-Agent" => USER_AGENT
      }
    end

    def access_token
      @access_token ||= fetch_access_token
    end

    def fetch_access_token
      response = with_retries("/oauth2/token") do
        self.class.post(
          "#{BASE_URI}/oauth2/token",
          body: { grant_type: "client_credentials", client_id: client_id, client_secret: client_secret },
          headers: { "Accept" => "application/json", "User-Agent" => USER_AGENT }
        )
      end

      case response.code
      when 200
        token = response.parsed_response.is_a?(Hash) ? response.parsed_response["access_token"] : nil
        token.presence || raise(ApiError.new("Sharesight returned no access token", status_code: response.code))
      when 400, 401
        raise AuthenticationError, "Sharesight rejected the API client (#{response.code}). Check your client ID and secret."
      else
        raise ApiError.new("Sharesight token request failed (status #{response.code})", status_code: response.code, response_body: response.body)
      end
    end

    def handle_response(response)
      case response.code
      when 200
        parsed = response.parsed_response
        return parsed if parsed.is_a?(Hash)

        raise ApiError.new("Sharesight returned an unexpected response", status_code: response.code, response_body: response.body)
      when 401, 403
        raise AuthenticationError, "Sharesight authentication failed (#{response.code}). Check your API client and that your plan includes API access."
      when 429
        raise RateLimitError, "Sharesight rate limit exceeded. Please wait before retrying."
      else
        raise ApiError.new("Sharesight API error (status #{response.code})", status_code: response.code, response_body: response.body)
      end
    end

    def with_retries(label, max_retries: 3)
      attempt = 0
      begin
        attempt += 1
        yield
      rescue *RETRYABLE_ERRORS => e
        raise if attempt >= max_retries

        delay = [ 2**attempt, 30 ].min
        DebugLogEntry.capture(
          category: "sync",
          level: "warn",
          message: "Provider::Sharesight #{label} attempt #{attempt} failed: #{e.message}. Retrying in #{delay}s",
          source: "sharesight",
          provider_key: "sharesight"
        )
        sleep(delay)
        retry
      end
    end
end
