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
  class RateLimitError < Error; end
  class ServerError < Error; end

  attr_reader :api_key

  def initialize(api_key:)
    @api_key = api_key
    validate_configuration!
  end

  # Returns all accounts across the user's connections.
  # Response items: { id, connectionId, provider, name, type, institutionName, accountNumber, currency }
  def list_accounts
    results, truncated = paginate("list_accounts", "#{BASE_URL}/accounts", page_size: ACCOUNTS_PAGE_SIZE)

    # A partial account list must never reach downstream pruning
    raise Error.new("list_accounts returned a truncated account list", :truncated) if truncated

    results
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
    fetch_transactions_window(
      connection_id: connection_id,
      account_id: account_id,
      start_date: start_date&.to_date,
      end_date: end_date&.to_date,
      include_pending: include_pending,
      splits_left: MAX_WINDOW_SPLITS
    )
  end

  private

    RETRYABLE_ERRORS = [
      SocketError, Net::OpenTimeout, Net::ReadTimeout,
      Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ETIMEDOUT, EOFError
    ].freeze

    MAX_RETRIES = 3
    INITIAL_RETRY_DELAY = 2 # seconds
    MAX_PAGES = 50 # safety cap so a bad hasMore can never loop forever
    MAX_WINDOW_SPLITS = 6 # bounds recursion when halving a truncated date window

    def validate_configuration!
      raise ConfigurationError, "Api key is required" if @api_key.blank?
    end

    # A truncated window cannot be paged past the row ceiling; halve the date
    # range and recurse until every window fits, raising once it cannot narrow
    def fetch_transactions_window(connection_id:, account_id:, start_date:, end_date:, include_pending:, splits_left:)
      query = {
        connectionId: connection_id,
        accountId: account_id
      }
      query[:from] = start_date.to_s if start_date
      query[:to] = end_date.to_s if end_date
      query[:includePending] = "true" if include_pending

      results, truncated = paginate("get_transactions", "#{BASE_URL}/transactions", page_size: TRANSACTIONS_PAGE_SIZE, query: query)
      return results unless truncated

      if start_date.nil? || end_date.nil? || splits_left <= 0 || start_date >= end_date
        raise Error.new("get_transactions hit the server row ceiling and the date window cannot be narrowed further", :truncated)
      end

      mid = start_date + ((end_date - start_date) / 2).to_i
      Rails.logger.info "Redbark API: get_transactions window #{start_date}..#{end_date} truncated, splitting at #{mid}"

      first_half = fetch_transactions_window(
        connection_id: connection_id, account_id: account_id,
        start_date: start_date, end_date: mid,
        include_pending: include_pending, splits_left: splits_left - 1
      )
      second_half = fetch_transactions_window(
        connection_id: connection_id, account_id: account_id,
        start_date: mid + 1, end_date: end_date,
        include_pending: include_pending, splits_left: splits_left - 1
      )

      (first_half + second_half).uniq { |t| t[:id] || t }
    end

    # Follows limit/offset pagination until hasMore is false. Returns
    # [results, truncated] - truncated means the server row ceiling fired
    # (X-Redbark-Truncated) and the caller decides how to recover
    def paginate(operation_name, url, page_size:, query: {})
      results = []
      offset = 0
      exhausted = false

      MAX_PAGES.times do
        page, headers = with_retries(operation_name) do
          response = self.class.get(
            url,
            headers: auth_headers,
            query: query.merge(limit: page_size, offset: offset)
          )
          [ handle_response(response), response.headers ]
        end

        data = page[:data] || []
        results.concat(data)

        if headers["x-redbark-truncated"].to_s == "true"
          return [ results, true ]
        end

        pagination = page[:pagination] || {}
        unless pagination[:hasMore]
          exhausted = true
          break
        end

        # hasMore with an empty page means the server stopped early
        if data.empty?
          raise Error.new("#{operation_name} returned an empty page while reporting more results", :truncated)
        end

        offset += data.size
      end

      unless exhausted
        raise Error.new("#{operation_name} exceeded #{MAX_PAGES} pages without exhausting results", :too_many_pages)
      end

      [ results, false ]
    end

    def with_retries(operation_name, max_retries: MAX_RETRIES)
      retries = 0

      begin
        yield
      rescue *RETRYABLE_ERRORS, RateLimitError, ServerError => e
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
          raise e if e.is_a?(Error)
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
    # Error messages carry the parsed provider message only, never the raw
    # response body - callers log and re-log these strings.
    def handle_response(response)
      case response.code
      when 200, 201
        JSON.parse(response.body, symbolize_names: true)
      when 400
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
        raise RateLimitError.new("Rate limit exceeded", :rate_limited)
      when 500..599
        raise ServerError.new("Redbark server error (#{response.code})", :server_error)
      else
        raise Error.new("Unexpected response #{response.code}: #{error_message_from(response)}", :unknown)
      end
    end

    def error_message_from(response)
      parsed = JSON.parse(response.body)
      parsed.dig("error", "message") || "no error message provided"
    rescue JSON::ParserError
      "unparseable error response"
    end
end
