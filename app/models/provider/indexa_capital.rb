# frozen_string_literal: true

class Provider::IndexaCapital
  include HTTParty

  headers "User-Agent" => "Sure Finance IndexaCapital Client"
  default_options.merge!(verify: true, ssl_verify_mode: OpenSSL::SSL::VERIFY_PEER, timeout: 120)

  class Error < StandardError
    attr_reader :error_type

    def initialize(message, error_type = :unknown)
      super(message)
      @error_type = error_type
    end
  end

  class ConfigurationError < Error; end
  class AuthenticationError < Error; end

  BASE_URL = "https://api.indexacapital.com"

  # Supports two auth modes:
  # 1. Username/document/password credentials (authenticates via /auth/authenticate)
  # 2. Pre-generated API token (from env or user dashboard)
  def initialize(username: nil, document: nil, password: nil, api_token: nil)
    @username = username
    @document = document
    @password = password
    @api_token = api_token
    validate_configuration!
  end

  # GET /users/me → list of accounts
  def list_accounts
    with_retries("list_accounts") do
      response = self.class.get(
        "#{base_url}/users/me",
        headers: auth_headers
      )
      data = handle_response(response)
      extract_accounts(data)
    end
  end

  # GET /accounts/{account_number}/fiscal-results → holdings (positions with cost basis)
  def get_holdings(account_number:)
    sanitize_account_number!(account_number)
    with_retries("get_holdings") do
      response = self.class.get(
        "#{base_url}/accounts/#{account_number}/fiscal-results",
        headers: auth_headers
      )
      handle_response(response)
    end
  end

  # GET /accounts/{account_number}/performance → latest portfolio total_amount
  def get_account_balance(account_number:)
    sanitize_account_number!(account_number)
    with_retries("get_account_balance") do
      response = self.class.get(
        "#{base_url}/accounts/#{account_number}/performance",
        headers: auth_headers
      )
      data = handle_response(response)
      extract_balance(data)
    end
  end

  # No activities/transactions endpoint exists in the Indexa Capital API.
  # Returns empty array to keep the interface consistent.
  def get_activities(account_number:, start_date: nil, end_date: nil)
    Rails.logger.info "Provider::IndexaCapital - No activities endpoint available for Indexa Capital API"
    []
  end

  private

    RETRYABLE_ERRORS = [
      SocketError, Net::OpenTimeout, Net::ReadTimeout,
      Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ETIMEDOUT, EOFError
    ].freeze

    MAX_RETRIES = 3
    INITIAL_RETRY_DELAY = 2 # seconds

    # Indexa Capital account numbers are 8-char alphanumeric (e.g., "LPYH3MCQ")
    def sanitize_account_number!(account_number)
      unless account_number.present? && account_number.match?(/\A[A-Za-z0-9]+\z/)
        raise Error.new("Invalid account number format: #{account_number}", :bad_request)
      end
    end

    attr_reader :username, :document, :password, :api_token

    def validate_configuration!
      return if @api_token.present?

      if @username.blank? || @document.blank? || @password.blank?
        raise ConfigurationError, "Either API token or all three username/document/password credentials are required"
      end
    end

    def token_auth?
      @api_token.present?
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
            "IndexaCapital API: #{operation_name} failed (attempt #{retries}/#{max_retries}): " \
            "#{e.class}: #{e.message}. Retrying in #{delay}s..."
          )
          sleep(delay)
          retry
        else
          Rails.logger.error(
            "IndexaCapital API: #{operation_name} failed after #{max_retries} retries: " \
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

    def base_url
      BASE_URL
    end

    def base_headers
      {
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }
    end

    def auth_headers
      base_headers.merge("X-AUTH-TOKEN" => token)
    end

    def token
      @token ||= token_auth? ? @api_token : authenticate!
    end

    def authenticate!
      response = self.class.post(
        "#{base_url}/auth/authenticate",
        headers: base_headers,
        body: {
          username: username,
          document: document,
          password: password
        }.to_json
      )
      payload = handle_response(response)
      jwt = payload[:token]
      raise AuthenticationError.new("Authentication token missing in response", :unauthorized) if jwt.blank?

      jwt
    end

    def handle_response(response)
      case response.code
      when 200, 201
        begin
          JSON.parse(response.body, symbolize_names: true)
        rescue JSON::ParserError => e
          raise Error.new("Invalid JSON in response: #{e.message}", :bad_response)
        end
      when 400
        Rails.logger.error "IndexaCapital API: Bad request - #{response.body}"
        raise Error.new("Bad request: #{response.body}", :bad_request)
      when 401
        raise AuthenticationError.new("Invalid credentials", :unauthorized)
      when 403
        raise AuthenticationError.new("Access forbidden - check your permissions", :access_forbidden)
      when 404
        raise Error.new("Resource not found", :not_found)
      when 429
        raise Error.new("Rate limit exceeded. Please try again later.", :rate_limited)
      when 500..599
        raise Error.new("IndexaCapital server error (#{response.code}). Please try again later.", :server_error)
      else
        Rails.logger.error "IndexaCapital API: Unexpected response - Code: #{response.code}, Body: #{response.body}"
        raise Error.new("Unexpected error: #{response.code} - #{response.body}", :unknown)
      end
    end

    # Extract accounts array from /users/me response
    # API returns: { accounts: [{ account_number: "ABC12345", type: "mutual", status: "active", ... }] }
    def extract_accounts(user_data)
      accounts = user_data[:accounts] || []
      accounts.map do |acct|
        {
          account_number: acct[:account_number],
          name: account_display_name(acct),
          type: acct[:type],
          status: acct[:status],
          currency: "EUR",
          raw: acct
        }.with_indifferent_access
      end
    end

    def account_display_name(acct)
      type_label = case acct[:type]
      when "mutual" then "Mutual Fund"
      when "pension", "epsv" then "Pension Plan"
      else acct[:type]&.titleize || "Account"
      end
      "Indexa Capital #{type_label} (#{acct[:account_number]})"
    end

    # Extract current balance from performance endpoint's portfolios array
    def extract_balance(performance_data)
      portfolios = performance_data[:portfolios]
      return 0 unless portfolios.is_a?(Array) && portfolios.any?

      latest = portfolios.max_by { |p| Date.parse(p[:date].to_s) rescue Date.new }
      latest[:total_amount].to_d
    end
end
