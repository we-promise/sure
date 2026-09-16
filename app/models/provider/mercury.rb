require "bigdecimal"

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

  # Bounded, precise reads for shared ingestion. Legacy API methods retain their
  # response shapes. Pagination references: docs.mercury.com/reference/getaccounts
  # and docs.mercury.com/reference/listaccounttransactions.
  def get_accounts_page(cursor: nil, limit: 1000)
    validate_ingestion_limit!(limit)
    raise MercuryError.new("Invalid account cursor", :invalid_response) unless cursor.nil? || (cursor.is_a?(String) && cursor.present?)
    payload = get_ingestion_json("/accounts", limit: limit, order: "asc", start_after: cursor)
    accounts = ingestion_records(payload, :accounts)
    raise MercuryError.new("Invalid account page size", :invalid_response) if accounts.size > limit
    next_cursor = accounts.size == limit ? accounts.last[:id] : nil
    unless next_cursor.nil? || (next_cursor.is_a?(String) && next_cursor.present? && next_cursor != cursor)
      raise MercuryError.new("Invalid account continuation", :invalid_response)
    end
    { items: accounts, next_cursor: next_cursor, evidence: payload }
  end

  def get_account_transactions_page(account_id, cursor: nil, start_date: nil, end_date: nil, limit: 1000)
    validate_ingestion_limit!(limit)
    unless cursor.nil? || (cursor.is_a?(String) && cursor.match?(/\A(?:0|[1-9]\d*)\z/))
      raise MercuryError.new("Invalid transaction cursor", :invalid_response)
    end
    offset = cursor ? Integer(cursor, 10) : 0
    payload = get_ingestion_json(
      "/account/#{ERB::Util.url_encode(account_id.to_s)}/transactions",
      start: ingestion_date(start_date), end: ingestion_date(end_date), offset: offset, limit: limit, order: "asc"
    )
    transactions = ingestion_records(payload, :transactions)
    raise MercuryError.new("Invalid transaction page size", :invalid_response) if transactions.size > limit
    consumed = offset + transactions.size
    total = payload[:total]
    if !total.nil? && (!total.is_a?(Integer) || total.negative? || consumed > total || (transactions.empty? && offset < total))
      raise MercuryError.new("Invalid transaction total", :invalid_response)
    end
    more = total.nil? ? transactions.size == limit : consumed < total
    { items: transactions, next_cursor: more ? consumed.to_s : nil, evidence: payload }
  end

  private

    def validate_ingestion_limit!(limit)
      raise MercuryError.new("Invalid page limit", :invalid_response) unless limit.is_a?(Integer) && (1..1000).cover?(limit)
    end

    def ingestion_records(payload, key)
      unless payload.is_a?(Hash) && payload[key].is_a?(Array) && payload[key].all? { |record| record.is_a?(Hash) } &&
          payload[:error].blank? && payload[:errors].blank?
        raise MercuryError.new("Invalid Mercury collection response", :invalid_response)
      end
      payload[key]
    end

    def ingestion_date(value)
      return nil if value.nil?
      return value.iso8601 if value.is_a?(Date) || value.is_a?(Time)
      raise MercuryError.new("Invalid request date", :invalid_response) unless value.is_a?(String) && value.present?
      value
    end

    def get_ingestion_json(path, **params)
      query = URI.encode_www_form(params.compact)
      response = self.class.get("#{base_url}#{path}?#{query}", headers: auth_headers)
      unless response.code == 200
        type = { 400 => :bad_request, 401 => :unauthorized, 403 => :access_forbidden, 404 => :not_found, 429 => :rate_limited }.fetch(response.code, :fetch_failed)
        raise MercuryError.new("Mercury request failed (HTTP #{response.code})", type)
      end
      JSON.parse(response.body, symbolize_names: true, decimal_class: BigDecimal)
    rescue MercuryError
      raise
    rescue JSON::ParserError, TypeError, ArgumentError
      raise MercuryError.new("Invalid Mercury response", :invalid_response), cause: nil
    rescue SocketError, Net::OpenTimeout, Net::ReadTimeout
      raise MercuryError.new("Mercury request failed", :request_failed), cause: nil
    end

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
