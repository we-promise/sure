# SnapTrade API client using SnapTrade OAuth apps (pre-release feature).
#
# Auth model:
#   - Instance admin registers an OAuth app on dashboard.snaptrade.com and sets
#     SNAPTRADE_OAUTH_CLIENT_ID / SNAPTRADE_OAUTH_CLIENT_SECRET.
#   - Users authorize via authorization-code + PKCE; per-item access/refresh
#     tokens are stored (encrypted) on SnaptradeItem.
#   - Data calls send Authorization: Bearer <access_token>. The SnapTrade user
#     is implicit in the token; there is no userId/userSecret.
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

  MAX_RETRIES = 3
  INITIAL_RETRY_DELAY = 2 # seconds
  MAX_RETRY_DELAY = 30 # seconds

  API_BASE_URL = "https://api.snaptrade.com".freeze
  AUTHORIZE_URL = "https://dashboard.snaptrade.com/oauth/authorize".freeze
  TOKEN_URL = "https://api.snaptrade.com/oauth/token/".freeze
  REVOKE_URL = "https://api.snaptrade.com/oauth/revoke_token/".freeze
  DASHBOARD_URL = "https://dashboard.snaptrade.com".freeze
  TOKEN_EXPIRY_LEEWAY = 60 # seconds; refresh this long before actual expiry

  class << self
    def oauth_configured?
      oauth_client_id.present? && oauth_client_secret.present?
    end

    def oauth_client_id
      Rails.configuration.x.snaptrade&.oauth_client_id
    end

    def oauth_client_secret
      Rails.configuration.x.snaptrade&.oauth_client_secret
    end

    # PKCE pair per RFC 7636 (S256)
    def generate_pkce
      verifier = SecureRandom.urlsafe_base64(64).delete("=")[0, 128]
      challenge = Base64.urlsafe_encode64(OpenSSL::Digest::SHA256.digest(verifier), padding: false)
      { verifier: verifier, challenge: challenge }
    end

    def authorize_url(redirect_uri:, state:, code_challenge:, scope: "read")
      raise ConfigurationError, "SnapTrade OAuth is not configured" unless oauth_configured?

      params = {
        response_type: "code",
        client_id: oauth_client_id,
        redirect_uri: redirect_uri,
        scope: scope,
        state: state,
        code_challenge: code_challenge,
        code_challenge_method: "S256"
      }
      "#{AUTHORIZE_URL}?#{params.to_query}"
    end

    def exchange_code(code:, redirect_uri:, code_verifier:)
      token_request(
        grant_type: "authorization_code",
        code: code,
        redirect_uri: redirect_uri,
        code_verifier: code_verifier
      )
    end

    def refresh_tokens(refresh_token:)
      token_request(grant_type: "refresh_token", refresh_token: refresh_token)
    end

    # Best-effort revocation (RFC 7009). Returns true on success.
    def revoke_token(token:)
      return false if token.blank?
      raise ConfigurationError, "SnapTrade OAuth is not configured" unless oauth_configured?

      response = oauth_connection.post(REVOKE_URL) do |request|
        request.headers["Authorization"] = basic_auth_header
        request.headers["Content-Type"] = "application/x-www-form-urlencoded"
        request.body = URI.encode_www_form(token: token)
      end
      response.success?
    rescue Faraday::Error => e
      Rails.logger.warn("SnapTrade token revocation failed: #{e.class} - #{e.message}")
      false
    end

    private

      def token_request(params)
        raise ConfigurationError, "SnapTrade OAuth is not configured" unless oauth_configured?

        response = oauth_connection.post(TOKEN_URL) do |request|
          request.headers["Authorization"] = basic_auth_header
          request.headers["Content-Type"] = "application/x-www-form-urlencoded"
          request.body = URI.encode_www_form(params)
        end

        payload = parse_json(response.body)
        return payload if response.success?

        error = payload["error_description"].presence || payload["error"].presence || "HTTP #{response.status}"
        if (400..499).cover?(response.status)
          raise AuthenticationError, "SnapTrade OAuth token request failed: #{error}"
        end

        raise ApiError.new(
          "SnapTrade OAuth token request failed: #{error}",
          status_code: response.status, response_body: response.body
        )
      end

      def basic_auth_header
        "Basic #{Base64.strict_encode64("#{oauth_client_id}:#{oauth_client_secret}")}"
      end

      def oauth_connection
        Faraday.new do |faraday|
          faraday.options.timeout = 30
          faraday.options.open_timeout = 10
        end
      end

      def parse_json(body)
        body.present? ? JSON.parse(body) : {}
      rescue JSON::ParserError
        {}
      end
  end

  attr_reader :snaptrade_item

  def initialize(snaptrade_item)
    raise ConfigurationError, "snaptrade_item is required" if snaptrade_item.nil?
    @snaptrade_item = snaptrade_item
  end

  # --- Data methods. The SnapTrade user is implicit in the Bearer token. ---

  # Returns Array<Hash> of brokerage accounts
  def list_accounts
    get_json("/api/v1/accounts")
  end

  # Returns Array<Hash> of balance entries
  def get_balances(account_id:)
    get_json("/api/v1/accounts/#{account_id}/balances")
  end

  # Returns Array<Hash> of positions
  def get_positions(account_id:)
    get_json("/api/v1/accounts/#{account_id}/positions")
  end

  # Returns raw JSON: paginated form is {"data" => [...]}, may also be a plain Array
  def get_account_activities(account_id:, start_date: nil, end_date: nil)
    params = {}
    params[:startDate] = start_date.to_date.to_s if start_date
    params[:endDate] = end_date.to_date.to_s if end_date
    get_json("/api/v1/accounts/#{account_id}/activities", params)
  end

  # Cross-account activities endpoint. Returns Array<Hash>.
  def get_activities(start_date: nil, end_date: nil, accounts: nil, brokerage_authorizations: nil, type: nil)
    params = {}
    params[:startDate] = start_date.to_date.to_s if start_date
    params[:endDate] = end_date.to_date.to_s if end_date
    params[:accounts] = accounts if accounts
    params[:brokerageAuthorizations] = brokerage_authorizations if brokerage_authorizations
    params[:type] = type if type
    get_json("/api/v1/activities", params)
  end

  # Returns Array<Hash> of brokerage authorizations (connections)
  def list_connections
    get_json("/api/v1/authorizations")
  end

  def delete_connection(authorization_id:)
    request_json(:delete, "/api/v1/authorizations/#{authorization_id}")
  end

  # Connection portal URL (loginUser). Returns the redirect URL string.
  def get_connection_url(redirect_url:, broker: nil)
    body = { customRedirect: redirect_url, connectionType: "read" }
    body[:broker] = broker if broker
    response = request_json(:post, "/api/v1/snapTrade/login", body: body)
    response["redirectURI"] || response["redirectUri"]
  end

  # Best-effort revocation of this item's tokens (used on destroy)
  def revoke_token!
    token = snaptrade_item.oauth_refresh_token.presence || snaptrade_item.oauth_access_token
    self.class.revoke_token(token: token)
  end

  private

    def get_json(path, params = {})
      request_json(:get, path, params: params)
    end

    def request_json(method, path, params: {}, body: nil, retry_on_auth_failure: true)
      ensure_fresh_token!
      operation = "#{method.to_s.upcase} #{path}"
      used_access_token = snaptrade_item.oauth_access_token

      response = with_retries(operation) do
        api_connection.public_send(method, "#{API_BASE_URL}#{path}") do |request|
          request.headers["Authorization"] = "Bearer #{used_access_token}"
          request.headers["Accept"] = "application/json"
          request.params.update(params) if params.present?
          if body
            request.headers["Content-Type"] = "application/json"
            request.body = body.to_json
          end
        end
      end

      if response.status == 401 && retry_on_auth_failure
        refresh_access_token!(previous_access_token: used_access_token)
        return request_json(method, path, params: params, body: body, retry_on_auth_failure: false)
      end

      handle_response(response, operation)
    end

    def ensure_fresh_token!
      raise AuthenticationError, "SnapTrade item has no access token" if snaptrade_item.oauth_access_token.blank?

      expires_at = snaptrade_item.oauth_token_expires_at
      return if expires_at.blank? || expires_at > TOKEN_EXPIRY_LEEWAY.seconds.from_now

      refresh_access_token!
    end

    # Guards against a concurrent refresh-token rotation race: multiple threads/processes
    # (e.g. per-account jobs sharing one SnapTrade item) may all observe an expiring/rejected
    # token and attempt to refresh at once. If SnapTrade rotates refresh tokens as single-use,
    # every refresh after the first would fail with invalid_grant and needlessly brick the
    # item. Taking a DB row lock and re-checking freshness after reload ensures only one
    # caller actually performs the HTTP refresh; the rest observe the winner's fresh token.
    #
    # `previous_access_token`, when present, means we're refreshing reactively after a 401 on
    # that specific token (called from request_json). In that case we skip the HTTP refresh
    # only if the DB row's access token has already changed since we made the failed request
    # (i.e. another caller already won the race) -- an expiry-based freshness check would be
    # wrong here since the server rejected a token we believed was still time-valid.
    # When `previous_access_token` is absent, we're refreshing proactively (from
    # ensure_fresh_token!) and skip only if the reloaded row is still time-fresh.
    def refresh_access_token!(previous_access_token: nil)
      snaptrade_item.with_lock do
        snaptrade_item.reload

        if previous_access_token.present?
          next if snaptrade_item.oauth_access_token != previous_access_token
        else
          expires_at = snaptrade_item.oauth_token_expires_at
          next if expires_at.present? && expires_at > TOKEN_EXPIRY_LEEWAY.seconds.from_now
        end

        refresh_token = snaptrade_item.oauth_refresh_token
        raise AuthenticationError, "SnapTrade item has no refresh token" if refresh_token.blank?

        payload = self.class.refresh_tokens(refresh_token: refresh_token)
        snaptrade_item.apply_oauth_tokens!(payload)
      end
    rescue AuthenticationError => e
      mark_requires_update!
      DebugLogEntry.capture(
        category: "provider_sync",
        level: :error,
        message: "SnapTrade token refresh failed: #{e.message}",
        source: "Provider::Snaptrade",
        provider_key: "snaptrade",
        family: snaptrade_item.try(:family),
        metadata: { snaptrade_item_id: snaptrade_item.try(:id) }
      )
      raise
    end

    def mark_requires_update!
      snaptrade_item.update!(status: :requires_update)
    rescue StandardError => e
      Rails.logger.warn("SnapTrade: could not mark item requires_update: #{e.message}")
    end

    def handle_response(response, operation)
      if response.success?
        return {} if response.body.blank?
        begin
          JSON.parse(response.body)
        rescue JSON::ParserError
          raise ApiError.new("SnapTrade API error (#{operation}): invalid JSON response",
                             status_code: response.status, response_body: response.body)
        end
      else
        Rails.logger.error("SnapTrade API error (#{operation}): #{response.status}")
        case response.status
        when 401, 403
          mark_requires_update!
          raise AuthenticationError, "Authentication failed (#{operation}): HTTP #{response.status}"
        when 429
          raise ApiError.new("Rate limit exceeded. Please try again later.",
                             status_code: response.status, response_body: response.body)
        when 500..599
          raise ApiError.new("SnapTrade server error (#{response.status}). Please try again later.",
                             status_code: response.status, response_body: response.body)
        else
          raise ApiError.new("SnapTrade API error (#{operation}): HTTP #{response.status}",
                             status_code: response.status, response_body: response.body)
        end
      end
    end

    def api_connection
      @api_connection ||= Faraday.new do |faraday|
        faraday.options.timeout = 30
        faraday.options.open_timeout = 10
      end
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
