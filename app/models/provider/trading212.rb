require "bigdecimal"

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
  API_PATH_PREFIX = "/api/v0".freeze

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

  def fetch_account_summary_page
    payload = get_for_ingestion("/equity/account/summary")
    raise ApiError, "Invalid Trading 212 account summary" unless payload.is_a?(Hash)
    { items: [ payload ], next_cursor: nil, evidence: payload }
  end

  def fetch_positions_page
    ingestion_page(get_for_ingestion("/equity/positions"))
  end

  def fetch_instruments_page
    ingestion_page(get_for_ingestion("/equity/metadata/instruments"))
  end

  def fetch_orders_page(cursor: nil)
    history_page("/equity/history/orders", cursor: cursor)
  end

  def fetch_dividends_page(cursor: nil)
    history_page("/equity/history/dividends", cursor: cursor)
  end

  def fetch_transactions_page(cursor: nil)
    history_page("/equity/history/transactions", cursor: cursor)
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

    def get(path, query: {}, exact: false, history_bucket: nil)
      request_path = path.delete_prefix(API_PATH_PREFIX)
      url = "#{base_uri}#{request_path}"
      response = with_retries(path) do
        throttle_history_request(history_bucket) if history_bucket
        self.class.get(url, headers: auth_headers, query: query.compact)
      end
      handle_response(response, exact: exact)
    end

    def get_for_ingestion(path, query: {}, history_bucket: nil)
      get(path, query: query, exact: true, history_bucket: history_bucket)
    rescue ApiError => error
      raise ApiError.new("Trading 212 account data request failed", status_code: error.status_code), cause: nil
    rescue *RETRYABLE_ERRORS, JSON::ParserError
      raise ApiError.new("Trading 212 account data request failed"), cause: nil
    end

    def ingestion_page(items, next_cursor: nil, evidence: items)
      unless items.is_a?(Array) && items.all? { |item| item.is_a?(Hash) } &&
          (next_cursor.nil? || (next_cursor.is_a?(String) && next_cursor.present?))
        raise ApiError, "Invalid Trading 212 page"
      end
      { items: items, next_cursor: next_cursor, evidence: evidence }
    end

    def history_page(path, cursor: nil)
      request_path = cursor ? checked_history_path(cursor, path) : path
      payload = get_for_ingestion(request_path, query: cursor ? {} : { limit: PAGE_LIMIT }, history_bucket: path)
      raise ApiError, "Invalid Trading 212 history page" unless payload.is_a?(Hash)
      if payload["items"].is_a?(Array) && payload["items"].size > PAGE_LIMIT
        raise ApiError, "Invalid Trading 212 history page size"
      end
      next_cursor = payload["nextPagePath"]
      checked_history_path(next_cursor, path) unless next_cursor.nil?
      ingestion_page(payload["items"], next_cursor: next_cursor, evidence: payload)
    end

    def checked_history_path(value, endpoint)
      raise ApiError, "Invalid Trading 212 continuation" unless value.is_a?(String) && value.present?
      uri = URI.parse(value)
      unless uri.host.nil? && uri.scheme.nil? && uri.userinfo.nil? && uri.fragment.nil? &&
          [ endpoint, "#{API_PATH_PREFIX}#{endpoint}" ].include?(uri.path)
        raise ApiError, "Invalid Trading 212 continuation"
      end
      value
    rescue URI::InvalidURIError
      raise ApiError, "Invalid Trading 212 continuation", cause: nil
    end

    def throttle_history_request(endpoint)
      @history_requested_at ||= {}
      elapsed = Time.current - (@history_requested_at[endpoint] || Time.at(0))
      sleep(10 - elapsed) if elapsed < 10
      @history_requested_at[endpoint] = Time.current
    end

    def fetch_all_pages(path)
      items = []
      next_page_path = nil
      pages_fetched = 0

      loop do
        data = next_page_path ? get(next_page_path) : get(path, query: { limit: PAGE_LIMIT })
        items.concat(Array(data["items"]))

        next_page_path = data["nextPagePath"]
        pages_fetched += 1

        break if next_page_path.nil? || pages_fetched >= MAX_PAGES

        sleep(10)  # 6 req/min limit on history endpoint
      end

      items
    end

    def handle_response(response, exact: false)
      case response.code
      when 200, 201
        exact ? JSON.parse(response.body, decimal_class: BigDecimal) : response.parsed_response
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
