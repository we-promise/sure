class Provider::Snaptrade
  class Error < StandardError; end
  class AuthenticationError < Error; end
  class ConfigurationError < Error; end
  class ApiError < Error
    attr_reader :status_code, :response_body

    def initialize(message, status_code: nil, response_body: nil)
      super(message)
      @status_code = status_code
      @response_body = response_body
    end
  end

  # Retry configuration for transient network failures
  MAX_RETRIES = 3
  INITIAL_RETRY_DELAY = 2 # seconds
  MAX_RETRY_DELAY = 30 # seconds
  OAUTH_DISCOVERY_URL = "https://api.snaptrade.com/.well-known/oauth-authorization-server".freeze
  DEVICE_CODE_GRANT = "urn:ietf:params:oauth:grant-type:device_code".freeze

  attr_reader :client, :client_id, :consumer_key

  def initialize(client_id:, consumer_key:)
    raise ConfigurationError, "client_id is required" if client_id.blank?
    raise ConfigurationError, "consumer_key is required" if consumer_key.blank?

    @client_id = client_id
    @consumer_key = consumer_key

    configuration = SnapTrade::Configuration.new
    configuration.client_id = client_id
    configuration.consumer_key = consumer_key
    @client = SnapTrade::Client.new(configuration)
  end

  def oauth_authorization_server_metadata
    with_retries("oauth_authorization_server_metadata") do
      response = oauth_connection.get(OAUTH_DISCOVERY_URL)
      parse_oauth_response(response, "oauth_authorization_server_metadata")
    end
  end

  def start_device_authorization(scope: "read")
    metadata = oauth_authorization_server_metadata
    endpoint = metadata.fetch("device_authorization_endpoint") do
      raise ApiError.new("SnapTrade OAuth metadata missing device_authorization_endpoint")
    end

    with_retries("start_device_authorization") do
      response = oauth_connection.post(endpoint) do |request|
        request.headers["Content-Type"] = "application/x-www-form-urlencoded"
        request.body = URI.encode_www_form(
          client_id: oauth_client_id,
          scope: scope
        )
      end

      parse_oauth_response(response, "start_device_authorization")
    end
  end

  def poll_device_token(device_code:)
    raise ConfigurationError, "device_code is required" if device_code.blank?

    metadata = oauth_authorization_server_metadata
    endpoint = metadata.fetch("token_endpoint") do
      raise ApiError.new("SnapTrade OAuth metadata missing token_endpoint")
    end

    with_retries("poll_device_token") do
      response = oauth_connection.post(endpoint) do |request|
        request.headers["Content-Type"] = "application/x-www-form-urlencoded"
        request.body = URI.encode_www_form(
          grant_type: DEVICE_CODE_GRANT,
          device_code: device_code,
          client_id: oauth_client_id
        )
      end

      parse_oauth_response(response, "poll_device_token")
    end
  end

  # Register a new SnapTrade user
  # Returns { user_id: String, user_secret: String }
  def register_user(user_id)
    with_retries("register_user") do
      response = client.authentication.register_snap_trade_user(
        user_id: user_id
      )
      {
        user_id: response.user_id,
        user_secret: response.user_secret
      }
    end
  rescue SnapTrade::ApiError => e
    handle_api_error(e, "register_user")
  end

  # Delete a SnapTrade user (resets all connections)
  def delete_user(user_id:)
    with_retries("delete_user") do
      client.authentication.delete_snap_trade_user(
        user_id: user_id
      )
    end
  rescue SnapTrade::ApiError => e
    handle_api_error(e, "delete_user")
  end

  # List all registered users
  def list_users
    with_retries("list_users") do
      client.authentication.list_snap_trade_users
    end
  rescue SnapTrade::ApiError => e
    handle_api_error(e, "list_users")
  end

  # List all brokerage connections/authorizations
  def list_connections(user_id:, user_secret:)
    with_retries("list_connections") do
      client.connections.list_brokerage_authorizations(
        user_id: user_id,
        user_secret: user_secret
      )
    end
  rescue SnapTrade::ApiError => e
    handle_api_error(e, "list_connections")
  end

  # Delete a specific brokerage connection/authorization
  # This frees up one of your connection slots
  def delete_connection(user_id:, user_secret:, authorization_id:)
    with_retries("delete_connection") do
      client.connections.remove_brokerage_authorization(
        user_id: user_id,
        user_secret: user_secret,
        authorization_id: authorization_id
      )
    end
  rescue SnapTrade::ApiError => e
    handle_api_error(e, "delete_connection")
  end

  # Get connection portal URL (OAuth-like redirect to SnapTrade)
  # Returns the redirect URL string
  def get_connection_url(user_id:, user_secret:, redirect_url:, broker: nil)
    with_retries("get_connection_url") do
      response = client.authentication.login_snap_trade_user(
        user_id: user_id,
        user_secret: user_secret,
        custom_redirect: redirect_url,
        connection_type: "read",
        broker: broker
      )
      response.redirect_uri
    end
  rescue SnapTrade::ApiError => e
    handle_api_error(e, "get_connection_url")
  end

  # List connected brokerage accounts
  # Returns array of account objects
  def list_accounts(user_id:, user_secret:)
    with_retries("list_accounts") do
      client.account_information.list_user_accounts(
        user_id: user_id,
        user_secret: user_secret
      )
    end
  rescue SnapTrade::ApiError => e
    handle_api_error(e, "list_accounts")
  end

  # Get account details
  def get_account_details(user_id:, user_secret:, account_id:)
    with_retries("get_account_details") do
      client.account_information.get_user_account_details(
        user_id: user_id,
        user_secret: user_secret,
        account_id: account_id
      )
    end
  rescue SnapTrade::ApiError => e
    handle_api_error(e, "get_account_details")
  end

  # Get positions/holdings for an account
  # Returns array of position objects
  def get_positions(user_id:, user_secret:, account_id:)
    with_retries("get_positions") do
      client.account_information.get_user_account_positions(
        user_id: user_id,
        user_secret: user_secret,
        account_id: account_id
      )
    end
  rescue SnapTrade::ApiError => e
    handle_api_error(e, "get_positions")
  end

  # Get all holdings across all accounts
  def get_all_holdings(user_id:, user_secret:)
    with_retries("get_all_holdings") do
      client.account_information.get_all_user_holdings(
        user_id: user_id,
        user_secret: user_secret
      )
    end
  rescue SnapTrade::ApiError => e
    handle_api_error(e, "get_all_holdings")
  end

  # Get holdings for a specific account (includes more details)
  def get_holdings(user_id:, user_secret:, account_id:)
    with_retries("get_holdings") do
      client.account_information.get_user_holdings(
        user_id: user_id,
        user_secret: user_secret,
        account_id: account_id
      )
    end
  rescue SnapTrade::ApiError => e
    handle_api_error(e, "get_holdings")
  end

  # Get balances for an account
  def get_balances(user_id:, user_secret:, account_id:)
    with_retries("get_balances") do
      client.account_information.get_user_account_balance(
        user_id: user_id,
        user_secret: user_secret,
        account_id: account_id
      )
    end
  rescue SnapTrade::ApiError => e
    handle_api_error(e, "get_balances")
  end

  # Get activity/transaction history for a specific account
  # Supports pagination via start_date and end_date
  def get_account_activities(user_id:, user_secret:, account_id:, start_date: nil, end_date: nil)
    with_retries("get_account_activities") do
      params = {
        user_id: user_id,
        user_secret: user_secret,
        account_id: account_id
      }
      params[:start_date] = start_date.to_date.to_s if start_date
      params[:end_date] = end_date.to_date.to_s if end_date

      client.account_information.get_account_activities(**params)
    end
  rescue SnapTrade::ApiError => e
    handle_api_error(e, "get_account_activities")
  end

  # Get activities across all accounts (alternative endpoint)
  def get_activities(user_id:, user_secret:, start_date: nil, end_date: nil, accounts: nil, brokerage_authorizations: nil, type: nil)
    with_retries("get_activities") do
      params = {
        user_id: user_id,
        user_secret: user_secret
      }
      params[:start_date] = start_date.to_date.to_s if start_date
      params[:end_date] = end_date.to_date.to_s if end_date
      params[:accounts] = accounts if accounts
      params[:brokerage_authorizations] = brokerage_authorizations if brokerage_authorizations
      params[:type] = type if type

      client.transactions_and_reporting.get_activities(**params)
    end
  rescue SnapTrade::ApiError => e
    handle_api_error(e, "get_activities")
  end

  private

    def handle_api_error(error, operation)
      status = error.code
      body = error.response_body

      Rails.logger.error("SnapTrade API error (#{operation}): #{status} - #{error.message}")

      case status
      when 401, 403
        raise AuthenticationError, "Authentication failed: #{error.message}"
      when 429
        raise ApiError.new("Rate limit exceeded. Please try again later.", status_code: status, response_body: body)
      when 500..599
        raise ApiError.new("SnapTrade server error (#{status}). Please try again later.", status_code: status, response_body: body)
      else
        raise ApiError.new("SnapTrade API error: #{error.message}", status_code: status, response_body: body)
      end
    end

    def oauth_connection
      @oauth_connection ||= Faraday.new do |faraday|
        faraday.options.timeout = 30
        faraday.options.open_timeout = 10
      end
    end

    def oauth_client_id
      configured_client_id = Rails.configuration.x.snaptrade&.oauth_client_id
      return configured_client_id if configured_client_id.present?

      raise ConfigurationError, "SnapTrade OAuth client ID is not configured"
    end

    def parse_oauth_response(response, operation)
      payload = response.body.present? ? JSON.parse(response.body) : {}

      if response.success?
        payload
      else
        error = payload["error_description"].presence || payload["error"].presence || response.reason_phrase
        raise ApiError.new("SnapTrade OAuth error (#{operation}): #{error}", status_code: response.status, response_body: response.body)
      end
    rescue JSON::ParserError
      raise ApiError.new("SnapTrade OAuth error (#{operation}): invalid JSON response", status_code: response.status, response_body: response.body)
    end

    def with_retries(operation_name, max_retries: MAX_RETRIES)
      retries = 0

      begin
        yield
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Errno::ECONNRESET, Errno::ETIMEDOUT => e
        retries += 1

        if retries <= max_retries
          delay = calculate_retry_delay(retries)
          Rails.logger.warn(
            "SnapTrade API: #{operation_name} failed (attempt #{retries}/#{max_retries}): " \
            "#{e.class}: #{e.message}. Retrying in #{delay}s..."
          )
          sleep(delay)
          retry
        else
          Rails.logger.error(
            "SnapTrade API: #{operation_name} failed after #{max_retries} retries: " \
            "#{e.class}: #{e.message}"
          )
          raise ApiError.new("Network error after #{max_retries} retries: #{e.message}")
        end
      end
    end

    def calculate_retry_delay(retry_count)
      base_delay = INITIAL_RETRY_DELAY * (2 ** (retry_count - 1))
      jitter = base_delay * rand * 0.25
      [ base_delay + jitter, MAX_RETRY_DELAY ].min
    end
end
