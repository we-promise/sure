# frozen_string_literal: true

class Provider::Redbark
  include HTTParty

  headers "User-Agent" => "Sure Finance Redbark Client"
  default_options.merge!(verify: true, ssl_verify_mode: OpenSSL::SSL::VERIFY_PEER, timeout: 120)

  BASE_URL = "https://api.redbark.com/v1"

  # Server-side maximums for limit/offset pagination
  ACCOUNTS_PAGE_SIZE = 200
  TRANSACTIONS_PAGE_SIZE = 500

  class Error < StandardError
    attr_reader :error_type

    def initialize(message, error_type = :unknown)
      super(message)
      @error_type = error_type
    end
  end

  class ConfigurationError < Error; end
  class AuthenticationError < Error; end

  attr_reader :api_key

  def initialize(api_key:)
    @api_key = api_key
    validate_configuration!
  end

  # Returns all accounts across the user's connections.
  # Response items: { id, connectionId, provider, name, type, institutionName, accountNumber, currency }
  def list_accounts
    paginate("list_accounts", "#{BASE_URL}/accounts", page_size: ACCOUNTS_PAGE_SIZE)
  end

  # Returns all connections: { id, provider, category, institutionId, institutionName,
  # institutionLogo, status, lastRefreshedAt, createdAt }
  def list_connections
    with_retries("list_connections") do
      response = self.class.get("#{BASE_URL}/connections", headers: auth_headers)
      handle_response(response)[:data] || []
    end
  end

  # Returns balances for the given account ids.
  # Response items: { accountId, currentBalance, availableBalance, currency }
  def get_balances(account_ids:)
    return [] if account_ids.blank?

    with_retries("get_balances") do
      response = self.class.get(
        "#{BASE_URL}/balances",
        headers: auth_headers,
        query: { accountIds: Array(account_ids).join(",") }
      )
      handle_response(response)[:data] || []
    end
  end

  # Returns all transactions for one account within the date range.
  # Both connection_id and account_id are required by the API.
  # Response items: { id, accountId, accountName, status, date, datetime, postDate,
  # postDatetime, valueDate, valueDatetime, description, amount, direction, category,
  # merchantName, merchantCategoryCode }
  # Amounts are pre-signed decimal strings: positive = credit (money in), negative = debit.
  def get_transactions(connection_id:, account_id:, start_date: nil, end_date: nil, include_pending: false)
    query = {
      connectionId: connection_id,
      accountId: account_id
    }
    query[:from] = start_date.to_date.to_s if start_date
    query[:to] = end_date.to_date.to_s if end_date
    query[:includePending] = "true" if include_pending

    paginate("get_transactions", "#{BASE_URL}/transactions", page_size: TRANSACTIONS_PAGE_SIZE, query: query)
  end

  private

    RETRYABLE_ERRORS = [
      SocketError, Net::OpenTimeout, Net::ReadTimeout,
      Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ETIMEDOUT, EOFError
    ].freeze

    MAX_RETRIES = 3
    INITIAL_RETRY_DELAY = 2 # seconds
    MAX_PAGES = 50 # safety cap so a bad hasMore can never loop forever

    def validate_configuration!
      raise ConfigurationError, "Api key is required" if @api_key.blank?
    end

    # Follows limit/offset pagination until hasMore is false, returns the combined data array
    def paginate(operation_name, url, page_size:, query: {})
      results = []
      offset = 0

      MAX_PAGES.times do
        page = with_retries(operation_name) do
          response = self.class.get(
            url,
            headers: auth_headers,
            query: query.merge(limit: page_size, offset: offset)
          )
          handle_response(response)
        end

        data = page[:data] || []
        results.concat(data)

        pagination = page[:pagination] || {}
        break unless pagination[:hasMore] && data.any?

        offset += data.size
      end

      results
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
            "Redbark API: #{operation_name} failed (attempt #{retries}/#{max_retries}): " \
            "#{e.class}: #{e.message}. Retrying in #{delay}s..."
          )
          sleep(delay)
          retry
        else
          Rails.logger.error(
            "Redbark API: #{operation_name} failed after #{max_retries} retries: " \
            "#{e.class}: #{e.message}"
          )
          raise Error.new("Network error after #{max_retries} retries: #{e.message}", :network_error)
        end
      end
    end

    def calculate_retry_delay(retry_count)
      base_delay = INITIAL_RETRY_DELAY * (2 ** (retry_count - 1))
      jitter = base_delay * rand * 0.25
      [ base_delay + jitter, 30 ].min
    end

    def auth_headers
      {
        "Authorization" => "Bearer #{@api_key}",
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }
    end

    # Redbark error envelope: { error: { message, code, details } }
    def handle_response(response)
      case response.code
      when 200, 201
        JSON.parse(response.body, symbolize_names: true)
      when 400
        Rails.logger.error "Redbark API: Bad request - #{response.body}"
        raise Error.new("Bad request: #{error_message_from(response)}", :bad_request)
      when 401
        raise AuthenticationError.new("Invalid API key", :unauthorized)
      when 403
        raise AuthenticationError.new("Access forbidden - your Redbark plan may not include API access", :access_forbidden)
      when 404
        raise Error.new("Resource not found", :not_found)
      when 410
        raise Error.new("Endpoint requires an accountId: #{error_message_from(response)}", :bad_request)
      when 429
        raise Error.new("Rate limit exceeded. Please try again later.", :rate_limited)
      when 500..599
        raise Error.new("Redbark server error (#{response.code}). Please try again later.", :server_error)
      else
        Rails.logger.error "Redbark API: Unexpected response - Code: #{response.code}, Body: #{response.body}"
        raise Error.new("Unexpected error: #{response.code} - #{error_message_from(response)}", :unknown)
      end
    end

    def error_message_from(response)
      parsed = JSON.parse(response.body)
      parsed.dig("error", "message") || response.body.to_s.truncate(200)
    rescue JSON::ParserError
      response.body.to_s.truncate(200)
    end
end
