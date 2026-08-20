# SnapTrade API client for the device-flow auth model.
#
# Auth model:
#   - The family stores its own SnapTrade API credentials (client_id /
#     consumer_key) on SnaptradeItem, and a SnapTrade user is registered
#     against them (snaptrade_user_id / snaptrade_user_secret).
#   - The user authorizes Sure through the OAuth device flow, using the
#     deployment-wide public client id in SNAPTRADE_OAUTH_CLIENT_ID.
#   - Data calls go through the SnapTrade SDK and are scoped by the registered
#     user's id/secret, which are bound at construction.
#
# The authorization-code + PKCE model added in #2747 is deprecated but still
# supported for connections made under it; see Provider::SnaptradeOauth. Both
# clients expose the same data-method signatures and return plain hashes, so
# everything downstream of SnaptradeItem#snaptrade_provider is auth-agnostic.
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

  DASHBOARD_URL = "https://dashboard.snaptrade.com".freeze
  OAUTH_DISCOVERY_URL = "https://api.snaptrade.com/.well-known/oauth-authorization-server".freeze
  DEVICE_CODE_GRANT = "urn:ietf:params:oauth:grant-type:device_code".freeze

  attr_reader :client_id, :consumer_key, :user_id, :user_secret

  def initialize(client_id: nil, consumer_key: nil, user_id: nil, user_secret: nil)
    @client_id = client_id
    @consumer_key = consumer_key
    @user_id = user_id
    @user_secret = user_secret

    return if client_id.blank? && consumer_key.blank?
    raise ConfigurationError, "client_id is required" if client_id.blank?
    raise ConfigurationError, "consumer_key is required" if consumer_key.blank?

    configuration = SnapTrade::Configuration.new
    configuration.client_id = client_id
    configuration.consumer_key = consumer_key
    @client = SnapTrade::Client.new(configuration)
  end

  def self.oauth_client_id_configured?
    Rails.configuration.x.snaptrade&.oauth_client_id.present?
  end

  # --- OAuth device flow. Only needs the deployment's public client id. ---

  def oauth_authorization_server_metadata
    @oauth_authorization_server_metadata ||= with_retries("oauth_authorization_server_metadata") do
      response = oauth_connection.get(OAUTH_DISCOVERY_URL)
      parse_oauth_response(response, "oauth_authorization_server_metadata")
    end
  end

  def start_device_authorization(scope: "read")
    client_id = oauth_client_id
    metadata = oauth_authorization_server_metadata
    endpoint = metadata.fetch("device_authorization_endpoint") do
      raise ApiError.new("SnapTrade OAuth metadata missing device_authorization_endpoint")
    end

    with_retries("start_device_authorization") do
      response = oauth_connection.post(endpoint) do |request|
        request.headers["Content-Type"] = "application/x-www-form-urlencoded"
        request.body = URI.encode_www_form(
          client_id: client_id,
          scope: scope
        )
      end

      parse_oauth_response(response, "start_device_authorization")
    end
  end

  def poll_device_token(device_code:)
    raise ConfigurationError, "device_code is required" if device_code.blank?

    client_id = oauth_client_id
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
          client_id: client_id
        )
      end

      parse_oauth_response(response, "poll_device_token")
    end
  end

  # --- User registration. Needs the API credentials, not a registered user. ---

  # Register a new SnapTrade user. Returns { user_id: String, user_secret: String }.
  #
  # Deliberately not retried: registration is a non-idempotent create whose
  # user_secret is returned exactly once, so replaying a request whose response
  # was lost would strand an upstream user and burn a connection slot.
  def register_user(new_user_id)
    response = client.authentication.register_snap_trade_user(
      user_id: new_user_id
    )
    {
      user_id: response.user_id,
      user_secret: response.user_secret
    }
  rescue SnapTrade::ApiError => e
    handle_api_error(e, "register_user")
  rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Errno::ECONNRESET, Errno::ETIMEDOUT => e
    Rails.logger.error("SnapTrade API: register_user failed (not retried, non-idempotent): #{e.class}: #{e.message}")
    raise ApiError.new("Network error (not retried, non-idempotent request): #{e.message}")
  end

  # Delete a SnapTrade user (resets all their connections)
  def delete_user(user_id:)
    with_retries("delete_user") do
      client.authentication.delete_snap_trade_user(
        user_id: user_id
      )
    end
  rescue SnapTrade::ApiError => e
    handle_api_error(e, "delete_user")
  end

  # List all users registered under these API credentials
  def list_users
    with_retries("list_users") do
      normalize(client.authentication.list_snap_trade_users)
    end
  rescue SnapTrade::ApiError => e
    handle_api_error(e, "list_users")
  end

  # --- Data methods. Scoped by the registered user bound at construction. ---

  # Returns Array<Hash> of brokerage accounts
  def list_accounts
    with_retries("list_accounts") do
      normalize(client.account_information.list_user_accounts(**user_credentials))
    end
  rescue SnapTrade::ApiError => e
    handle_api_error(e, "list_accounts")
  end

  # Returns Array<Hash> of balance entries
  def get_balances(account_id:)
    with_retries("get_balances") do
      normalize(client.account_information.get_user_account_balance(
        **user_credentials,
        account_id: account_id
      ))
    end
  rescue SnapTrade::ApiError => e
    handle_api_error(e, "get_balances")
  end

  # Returns Array<Hash> of positions
  def get_positions(account_id:)
    with_retries("get_positions") do
      normalize(client.account_information.get_user_account_positions(
        **user_credentials,
        account_id: account_id
      ))
    end
  rescue SnapTrade::ApiError => e
    handle_api_error(e, "get_positions")
  end

  # Returns raw JSON: paginated form is {"data" => [...]}, may also be a plain Array
  def get_account_activities(account_id:, start_date: nil, end_date: nil)
    with_retries("get_account_activities") do
      params = user_credentials.merge(account_id: account_id)
      params[:start_date] = start_date.to_date.to_s if start_date
      params[:end_date] = end_date.to_date.to_s if end_date

      normalize(client.account_information.get_account_activities(**params))
    end
  rescue SnapTrade::ApiError => e
    handle_api_error(e, "get_account_activities")
  end

  # Cross-account activities endpoint. Returns Array<Hash>.
  def get_activities(start_date: nil, end_date: nil, accounts: nil, brokerage_authorizations: nil, type: nil)
    with_retries("get_activities") do
      params = user_credentials
      params[:start_date] = start_date.to_date.to_s if start_date
      params[:end_date] = end_date.to_date.to_s if end_date
      params[:accounts] = accounts if accounts
      params[:brokerage_authorizations] = brokerage_authorizations if brokerage_authorizations
      params[:type] = type if type

      normalize(client.transactions_and_reporting.get_activities(**params))
    end
  rescue SnapTrade::ApiError => e
    handle_api_error(e, "get_activities")
  end

  # Returns Array<Hash> of brokerage authorizations (connections)
  def list_connections
    with_retries("list_connections") do
      normalize(client.connections.list_brokerage_authorizations(**user_credentials))
    end
  rescue SnapTrade::ApiError => e
    handle_api_error(e, "list_connections")
  end

  # Delete a brokerage connection, freeing up one connection slot
  def delete_connection(authorization_id:)
    client.connections.remove_brokerage_authorization(
      **user_credentials,
      authorization_id: authorization_id
    )
  rescue SnapTrade::ApiError => e
    handle_api_error(e, "delete_connection")
  rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Errno::ECONNRESET, Errno::ETIMEDOUT => e
    Rails.logger.error("SnapTrade API: delete_connection failed (not retried, non-idempotent): #{e.class}: #{e.message}")
    raise ApiError.new("Network error (not retried, non-idempotent request): #{e.message}")
  end

  # Connection portal URL (loginUser). Returns the redirect URL string.
  def get_connection_url(redirect_url:, broker: nil)
    response = client.authentication.login_snap_trade_user(
      **user_credentials,
      custom_redirect: redirect_url,
      connection_type: "read",
      broker: broker
    )
    response.redirect_uri
  rescue SnapTrade::ApiError => e
    handle_api_error(e, "get_connection_url")
  rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Errno::ECONNRESET, Errno::ETIMEDOUT => e
    Rails.logger.error("SnapTrade API: get_connection_url failed (not retried, non-idempotent): #{e.class}: #{e.message}")
    raise ApiError.new("Network error (not retried, non-idempotent request): #{e.message}")
  end

  private

    def client
      @client || raise(ConfigurationError, "SnapTrade API credentials are required")
    end

    def user_credentials
      if user_id.blank? || user_secret.blank?
        raise ConfigurationError, "SnapTrade user is not registered"
      end

      { user_id: user_id, user_secret: user_secret }
    end

    # SDK responses are model objects; downstream code (importer, jobs, the
    # SnaptradeAccount upserts) works in plain hashes so that it does not have
    # to care which auth model produced the payload. SnapTrade's models expose
    # their wire shape -- API-cased keys, nested models resolved -- through
    # to_hash, which is what those hashes are keyed by everywhere else.
    def normalize(value)
      case value
      when Array
        value.map { |element| normalize(element) }
      when Hash
        value.to_h { |key, element| [ key, normalize(element) ] }
      when String, Symbol, Numeric, TrueClass, FalseClass, NilClass, Date, Time
        value
      when ->(object) { object.respond_to?(:to_hash) }
        normalize(value.to_hash)
      else
        JSON.parse(value.to_json)
      end
    rescue JSON::ParserError, TypeError
      value
    end

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
