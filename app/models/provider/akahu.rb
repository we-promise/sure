require "bigdecimal"
require "set"

class Provider::Akahu
  include HTTParty
  extend SslConfigurable

  DEFAULT_BASE_URL = "https://api.akahu.io/v1".freeze
  headers "User-Agent" => "Sure Finance Akahu Client"
  default_options.merge!({ timeout: 120 }.merge(httparty_ssl_options))

  attr_reader :app_token, :user_token

  def initialize(app_token:, user_token:)
    @app_token = app_token.to_s.strip
    @user_token = user_token.to_s.strip

    raise AkahuError.new("Akahu app token is required", :configuration_error) if @app_token.blank?
    raise AkahuError.new("Akahu user token is required", :configuration_error) if @user_token.blank?
  end

  def get_me
    payload = get("me")
    payload[:item] || payload
  end

  def get_accounts
    fetch_all("accounts")
  end

  def get_account(account_id)
    payload = get("accounts/#{ERB::Util.url_encode(account_id.to_s)}")
    payload[:item] || payload
  end

  def get_transactions(start_date: nil, end_date: nil)
    fetch_all("transactions", start_date: start_date, end_date: end_date)
  end

  def get_account_transactions(account_id:, start_date: nil, end_date: nil)
    fetch_all(
      "accounts/#{ERB::Util.url_encode(account_id.to_s)}/transactions",
      start_date: start_date,
      end_date: end_date
    )
  end

  def get_pending_transactions
    fetch_all("transactions/pending")
  end

  # Bounded, decimal-preserving reads for the canonical account-data adapter.
  # Legacy methods retain their response types and full-resource behavior.
  def get_accounts_page(cursor: nil)
    account_data_page("accounts", cursor: cursor)
  end

  def get_account_transactions_page(account_id:, start_date: nil, end_date: nil, cursor: nil)
    account_data_page("accounts/#{ERB::Util.url_encode(account_id.to_s)}/transactions",
      query: date_query(start_date: start_date, end_date: end_date), cursor: cursor)
  end

  def get_pending_transactions_page(cursor: nil)
    account_data_page("transactions/pending", cursor: cursor)
  end

  def refresh(account_id: nil)
    path = account_id.present? ? "refresh/#{ERB::Util.url_encode(account_id.to_s)}" : "refresh"
    post(path)
  end

  private

    def account_data_page(path, query: {}, cursor: nil)
      unless cursor.nil? || (cursor.is_a?(String) && cursor.present?)
        raise AkahuError.new("Invalid pagination cursor", :invalid_response)
      end
      query = query.merge(cursor: cursor) if cursor
      payload = with_retries("GET #{path}") do
        response = self.class.get(endpoint_url(path), headers: auth_headers, query: query.presence)
        if [ 200, 201 ].include?(response.code)
          JSON.parse(response.body, symbolize_names: true, decimal_class: BigDecimal)
        else
          handle_response(response)
        end
      end
      unless payload.is_a?(Hash) && payload[:items].is_a?(Array) && payload[:success] != false &&
          (payload[:cursor].nil? || payload[:cursor].is_a?(Hash))
        raise AkahuError.new("Invalid paginated response", :invalid_response)
      end
      next_cursor = payload.dig(:cursor, :next)
      unless next_cursor.nil? || (next_cursor.is_a?(String) && next_cursor.present?)
        raise AkahuError.new("Invalid pagination cursor", :invalid_response)
      end
      { items: payload[:items], next_cursor: next_cursor, evidence: payload }
    rescue JSON::ParserError
      raise AkahuError.new("Invalid paginated response", :invalid_response), cause: nil
    rescue AkahuError => error
      raise AkahuError.new("Akahu account data request failed", error.error_type), cause: nil
    end

    RETRYABLE_ERRORS = [
      SocketError,
      Net::OpenTimeout,
      Net::ReadTimeout,
      Errno::ECONNRESET,
      Errno::ECONNREFUSED,
      Errno::ETIMEDOUT,
      EOFError
    ].freeze

    MAX_RETRIES = 3
    INITIAL_RETRY_DELAY = 2

    def fetch_all(path, start_date: nil, end_date: nil)
      # Discovery and pending cleanup depend on complete inventories. Keep the
      # legacy Float decoder while refusing malformed or unfinished responses.
      query = date_query(start_date: start_date, end_date: end_date)
      cursor = nil
      results, seen, bytes = [], Set.new, 0

      1_000.times do
        page_query = cursor ? query.merge(cursor: cursor) : query
        payload = get(path, query: page_query)
        unless payload.is_a?(Hash) && payload[:items].is_a?(Array) && payload[:items].all? { |row| row.is_a?(Hash) } &&
            (!payload.key?(:success) || payload[:success] == true) && (payload[:cursor].nil? || payload[:cursor].is_a?(Hash))
          raise AkahuError.new("Invalid complete inventory response", :invalid_response)
        end
        cursor = payload.dig(:cursor, :next)
        unless cursor.nil? || (cursor.is_a?(String) && cursor.present? && seen.add?(cursor))
          raise AkahuError.new("Invalid inventory pagination cursor", :invalid_response)
        end
        bytes += JSON.generate(payload).bytesize
        results.concat(payload[:items])
        if results.size > 20_000 || bytes > 16 * 1024 * 1024
          raise AkahuError.new("Response exceeds its complete inventory bound", :invalid_response)
        end
        return results unless cursor
      end
      raise AkahuError.new("Response did not finish within its page bound", :invalid_response)
    end

    def date_query(start_date:, end_date:)
      query = {}
      query[:start] = format_api_time(start_date) if start_date.present?
      query[:end] = format_api_time(end_date) if end_date.present?
      query
    end

    def format_api_time(value)
      return Time.utc(value.year, value.month, value.day).iso8601(3) if value.is_a?(Date) && !value.is_a?(DateTime)

      value.to_time.utc.iso8601(3)
    end

    def get(path, query: {})
      with_retries("GET #{path}") do
        response = self.class.get(endpoint_url(path), headers: auth_headers, query: query.presence)
        handle_response(response)
      end
    end

    def post(path)
      with_retries("POST #{path}") do
        response = self.class.post(endpoint_url(path), headers: auth_headers)
        handle_response(response)
      end
    end

    def endpoint_url(path)
      "#{DEFAULT_BASE_URL}/#{path}"
    end

    def auth_headers
      {
        "Authorization" => "Bearer #{user_token}",
        "X-Akahu-Id" => app_token,
        "Accept" => "application/json"
      }
    end

    def with_retries(operation_name, max_retries: MAX_RETRIES)
      retries = 0

      begin
        yield
      rescue *RETRYABLE_ERRORS => e
        retries += 1
        if retries <= max_retries
          delay = calculate_retry_delay(retries)
          Rails.logger.warn(
            "Akahu API: #{operation_name} failed (attempt #{retries}/#{max_retries}): " \
            "#{e.class}: #{e.message}. Retrying in #{delay}s..."
          )
          sleep(delay)
          retry
        end

        Rails.logger.error("Akahu API: #{operation_name} failed after #{max_retries} retries: #{e.class}: #{e.message}")
        raise AkahuError.new("Network error after #{max_retries} retries: #{e.message}", :network_error)
      end
    end

    def calculate_retry_delay(retry_count)
      base_delay = INITIAL_RETRY_DELAY * (2 ** (retry_count - 1))
      jitter = base_delay * rand * 0.25
      [ base_delay + jitter, 30 ].min
    end

    def handle_response(response)
      case response.code
      when 200, 201
        parse_response_body(response)
      when 204
        {}
      when 400
        raise AkahuError.new("Bad request to Akahu API (#{response_diagnostics(response)})", :bad_request)
      when 401
        raise AkahuError.new("Invalid Akahu user token", :unauthorized)
      when 403
        raise AkahuError.new("Akahu access forbidden - check app token and permissions", :access_forbidden)
      when 404
        raise AkahuError.new("Akahu resource not found", :not_found)
      when 429
        raise AkahuError.new("Akahu rate limit exceeded. Please try again later.", :rate_limited)
      when 500..599
        raise AkahuError.new("Akahu server error (#{response.code}). Please try again later.", :server_error)
      else
        Rails.logger.error "Akahu API: Unexpected response status=#{response.code}"
        raise AkahuError.new("Failed to fetch Akahu data", :fetch_failed)
      end
    end

    def response_diagnostics(response)
      "status=#{response.code}"
    end

    def parse_response_body(response)
      return {} if response.body.blank?

      JSON.parse(response.body, symbolize_names: true)
    rescue JSON::ParserError => e
      Rails.logger.error "Akahu API: Failed to parse response: #{e.class}"
      raise AkahuError.new("Failed to parse Akahu API response", :parse_error)
    end

    class AkahuError < StandardError
      attr_reader :error_type

      def initialize(message, error_type = :unknown)
        super(message)
        @error_type = error_type
      end
    end
end
