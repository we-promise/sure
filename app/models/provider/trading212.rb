class Provider::Trading212
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

  LIVE_BASE_URI = "https://live.trading212.com/api/v0".freeze
  DEMO_BASE_URI = "https://demo.trading212.com/api/v0".freeze

  MAX_PAGES = 200
  PAGE_LIMIT = 50

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

  attr_reader :api_key, :api_secret, :environment

  def initialize(api_key:, api_secret:, environment: "live")
    raise ConfigurationError, "api_key is required" if api_key.blank?
    raise ConfigurationError, "api_secret is required" if api_secret.blank?
    raise ConfigurationError, "Invalid environment: #{environment}" unless %w[live demo].include?(environment.to_s)

    @api_key = api_key.to_s.strip
    @api_secret = api_secret.to_s.strip
    @environment = environment.to_s
  end

  def fetch_account_summary
    get("/equity/account/summary")
  end

  def fetch_positions
    get("/equity/positions")
  end

  def fetch_instruments
    get("/equity/metadata/instruments")
  end

  def fetch_all_orders
    fetch_all_pages("/equity/history/orders")
  end

  def fetch_all_dividends
    fetch_all_pages("/equity/history/dividends")
  end

  def fetch_all_transactions
    fetch_all_pages("/equity/history/transactions")
  end

  private

    def base_uri
      environment == "demo" ? DEMO_BASE_URI : LIVE_BASE_URI
    end

    def auth_headers
      encoded = Base64.strict_encode64("#{api_key}:#{api_secret}")
      {
        "Authorization" => "Basic #{encoded}",
        "Content-Type" => "application/json",
        "User-Agent" => "Sure Finance Trading 212 Client"
      }
    end

    def get(path, query: {})
      url = "#{base_uri}#{path}"
      response = with_retries(path) do
        self.class.get(url, headers: auth_headers, query: query.compact)
      end
      handle_response(response)
    end

    def fetch_all_pages(path)
      items = []
      cursor = nil
      pages_fetched = 0

      loop do
        query = { limit: PAGE_LIMIT }
        query[:cursor] = cursor if cursor

        data = get(path, query: query)
        items.concat(Array(data["items"]))

        next_page = data["nextPagePath"]
        pages_fetched += 1

        break if next_page.nil? || pages_fetched >= MAX_PAGES

        cursor = extract_cursor(next_page)
        break if cursor.nil?

        sleep(10)  # 6 req/min limit on history endpoint
      end

      items
    end

    def extract_cursor(next_page_path)
      uri = URI.parse("https://placeholder#{next_page_path}")
      params = URI.decode_www_form(uri.query.to_s).to_h
      params["cursor"]
    rescue URI::InvalidURIError
      nil
    end

    def handle_response(response)
      case response.code
      when 200, 201
        response.parsed_response
      when 401, 403
        raise AuthenticationError, "Trading 212 authentication failed (#{response.code}). Check your API key."
      when 429
        raise RateLimitError, "Trading 212 rate limit exceeded. Please wait before retrying."
      else
        raise ApiError.new(
          "Trading 212 API error (status #{response.code})",
          status_code: response.code,
          response_body: response.body
        )
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
          message: "Provider::Trading212 #{label} attempt #{attempt} failed: #{e.message}. Retrying in #{delay}s",
          source: "trading212",
          provider_key: "trading212"
        )
        sleep(delay)
        retry
      end
    end
end
