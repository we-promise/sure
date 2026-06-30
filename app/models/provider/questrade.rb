# frozen_string_literal: true

# Questrade API client.
#
# Auth model (the important part): Questrade uses single-use, rotating refresh
# tokens that EXPIRE 7 DAYS after generation. Exchanging a refresh token returns:
#   - access_token  (Bearer, ~30 min TTL)
#   - api_server    (the base URL you must use for all data calls)
#   - refresh_token (a BRAND NEW one — the old one is now dead)
#
# Because the refresh token is single-use, the new one MUST be persisted
# immediately and the exchange MUST be serialized (no two syncs refreshing at
# once). This SDK performs the exchange and hands the new credentials back to
# the caller via the `on_token_refresh` callback so the item model can persist
# them inside its own row lock / transaction.
class Provider::Questrade
  include HTTParty

  headers "User-Agent" => "Sure Finance Questrade Client"
  default_options.merge!(verify: true, ssl_verify_mode: OpenSSL::SSL::VERIFY_PEER, timeout: 120)

  LOGIN_URL         = "https://login.questrade.com/oauth2/token"
  # Questrade STRICTLY caps activity ranges at 31 days (err 1003). Used as an
  # inclusive day count, so a single window spans at most 30 days.
  MAX_ACTIVITY_DAYS = 30
  ACCESS_TOKEN_SKEW = 60   # refresh slightly early to avoid mid-call expiry

  class Error < StandardError
    attr_reader :error_type

    def initialize(message, error_type = :unknown)
      super(message)
      @error_type = error_type
    end
  end

  class ConfigurationError < Error; end
  class AuthenticationError < Error; end

  attr_reader :refresh_token, :api_server

  # @param refresh_token [String] current (single-use) refresh token
  # @param api_server [String, nil] cached base URL from the last exchange
  # @param on_token_refresh [#call] called with the new credentials hash
  #        { refresh_token:, api_server:, access_token:, expires_at: } so the
  #        caller can persist them. REQUIRED for durable operation.
  def initialize(refresh_token:, api_server: nil, on_token_refresh: nil)
    @refresh_token     = refresh_token
    @api_server        = api_server
    @on_token_refresh  = on_token_refresh
    @access_token      = nil
    @access_expires_at = nil
    validate_configuration!
  end

  # GET /v1/accounts -> { accounts: [...], userId: ... }
  def list_accounts
    get_json("v1/accounts")
  end

  # GET /v1/accounts/:id/positions  (Sure calls these "holdings")
  def get_holdings(account_id:)
    get_json("v1/accounts/#{account_id}/positions")
  end

  # GET /v1/accounts/:id/balances
  def get_balances(account_id:)
    get_json("v1/accounts/#{account_id}/balances")
  end

  # GET /v1/symbols?ids=1,2,3 -> currency/description per symbol. Questrade's
  # positions endpoint omits currency, so we use this to tag USD vs CAD holdings.
  def get_symbols(ids:)
    ids = Array(ids).compact.uniq.join(",")
    return { symbols: [] } if ids.blank?

    get_json("v1/symbols", query: { ids: ids })
  end

  # GET /v1/accounts/:id/activities?startTime=&endTime=
  # Chunked into <=30-day windows because Questrade rejects ranges > 31 days.
  def get_activities(account_id:, start_date:, end_date: Date.current)
    activities = []
    window_start = start_date.to_date
    end_date = end_date.to_date

    while window_start <= end_date
      # (MAX - 1) because the range is inclusive of both endpoints; this keeps the
      # span strictly under Questrade's 31-day ceiling even after UTC conversion.
      window_end = [ window_start + (MAX_ACTIVITY_DAYS - 1), end_date ].min
      page = get_json(
        "v1/accounts/#{account_id}/activities",
        query: { startTime: iso(window_start.beginning_of_day),
                 endTime:   iso(window_end.end_of_day) }
      )
      activities.concat(Array(page[:activities]))
      window_start = window_end + 1
    end

    { activities: activities }
  end

  private

    RETRYABLE_ERRORS = [
      SocketError, Net::OpenTimeout, Net::ReadTimeout,
      Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ETIMEDOUT, EOFError
    ].freeze

    MAX_RETRIES = 3
    INITIAL_RETRY_DELAY = 2 # seconds

    def validate_configuration!
      raise ConfigurationError.new("Refresh token is required", :missing_credentials) if @refresh_token.blank?
    end

    def get_json(path, query: {})
      ensure_authenticated!
      with_retries(path) do
        response = self.class.get("#{api_base}#{path}", headers: auth_headers, query: query)
        # Access token can expire mid-sync; refresh once and retry on 401.
        if response.code == 401
          authenticate!(force: true)
          response = self.class.get("#{api_base}#{path}", headers: auth_headers, query: query)
        end
        handle_response(response)
      end
    end

    # Exchange the refresh token unless we already hold a valid access token.
    def ensure_authenticated!
      authenticate! if @access_token.nil? || @access_expires_at.nil? || Time.current >= @access_expires_at
    end

    def authenticate!(force: false)
      return if @access_token && !force && Time.current < @access_expires_at

      response = with_retries("oauth_token") do
        self.class.get(LOGIN_URL, query: { grant_type: "refresh_token", refresh_token: @refresh_token })
      end

      unless response.code == 200
        # 400/401 here usually means the refresh token expired (>7 days) or was
        # already used. The connection must be re-authorized by the user.
        raise AuthenticationError.new(
          "Questrade token exchange failed (#{response.code}). Re-authorization required.",
          :reauth_required
        )
      end

      body = JSON.parse(response.body, symbolize_names: true)
      @access_token      = body[:access_token]
      @api_server        = body[:api_server]
      @refresh_token     = body[:refresh_token] # rotate in-memory immediately
      @access_expires_at = Time.current + (body[:expires_in].to_i - ACCESS_TOKEN_SKEW).seconds

      # Hand the new credentials to the caller to persist (single-use token!).
      @on_token_refresh&.call(
        refresh_token: @refresh_token,
        api_server:    @api_server,
        access_token:  @access_token,
        expires_at:    @access_expires_at
      )
    end

    def api_base
      raise ConfigurationError.new("No api_server; authenticate first", :missing_api_server) if @api_server.blank?
      @api_server.end_with?("/") ? @api_server : "#{@api_server}/"
    end

    def auth_headers
      {
        "Authorization" => "Bearer #{@access_token}",
        "Accept" => "application/json"
      }
    end

    def iso(time)
      time.utc.iso8601
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
            "Questrade API: #{operation_name} failed (attempt #{retries}/#{max_retries}): " \
            "#{e.class}: #{e.message}. Retrying in #{delay}s..."
          )
          sleep(delay)
          retry
        else
          Rails.logger.error(
            "Questrade API: #{operation_name} failed after #{max_retries} retries: " \
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

    def handle_response(response)
      case response.code
      when 200, 201
        JSON.parse(response.body, symbolize_names: true)
      when 400
        Rails.logger.error "Questrade API: Bad request - #{response.body}"
        raise Error.new("Bad request: #{response.body}", :bad_request)
      when 401
        raise AuthenticationError.new("Invalid or expired Questrade credentials", :unauthorized)
      when 403
        raise AuthenticationError.new("Access forbidden - check your permissions", :access_forbidden)
      when 404
        raise Error.new("Resource not found", :not_found)
      when 429
        raise Error.new("Questrade rate limit exceeded. Please try again later.", :rate_limited)
      when 500..599
        raise Error.new("Questrade server error (#{response.code}). Please try again later.", :server_error)
      else
        Rails.logger.error "Questrade API: Unexpected response - Code: #{response.code}, Body: #{response.body}"
        raise Error.new("Unexpected error: #{response.code} - #{response.body}", :unknown)
      end
    end
end
