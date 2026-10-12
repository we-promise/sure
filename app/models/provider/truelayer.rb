# TrueLayer Data API client (UK Open Banking).
#
# Authentication is OAuth 2.0: the user consents at TrueLayer's auth dialog,
# we exchange the returned code for an access token (valid ~1 hour) and a
# refresh token. TrueLayer rotates the refresh token on every refresh, so
# callers must persist the new one and must never refresh the same connection
# concurrently (see TruelayerItem#with_access_token).
#
# A client id starting with "sandbox-" switches every endpoint to TrueLayer's
# sandbox, which serves the "Mock Bank" provider.
#
# Docs: https://docs.truelayer.com/docs/data-api-basics
class Provider::Truelayer
  include HTTParty
  extend SslConfigurable

  headers "User-Agent" => "Sure Finance TrueLayer Client"
  default_options.merge!({ timeout: 120 }.merge(httparty_ssl_options))

  SCOPES = "accounts balance transactions cards offline_access".freeze
  # Mock Bank (sandbox) plus every UK Open Banking and OAuth provider.
  PROVIDERS = "uk-cs-mock uk-ob-all uk-oauth-all".freeze

  MAX_RETRIES = 2
  INITIAL_RETRY_DELAY = 2
  # The token endpoint is called under a row lock (TruelayerItem#fresh_access_token),
  # so it gets a short timeout and no retries to keep the lock brief.
  TOKEN_TIMEOUT = 20
  NETWORK_ERRORS = Provider::HttpTransport::TRANSPORT_ERRORS
  # 501 is excluded: some banks answer it for endpoints they don't support.
  RETRYABLE_STATUSES = [ 500, 502, 503, 504 ].freeze

  attr_reader :client_id, :client_secret

  def self.sandbox_client_id?(client_id)
    client_id.to_s.start_with?("sandbox-")
  end

  def initialize(client_id:, client_secret:)
    @client_id = client_id
    @client_secret = client_secret
  end

  def sandbox?
    self.class.sandbox_client_id?(client_id)
  end

  def auth_base_url
    sandbox? ? "https://auth.truelayer-sandbox.com" : "https://auth.truelayer.com"
  end

  def api_base_url
    sandbox? ? "https://api.truelayer-sandbox.com" : "https://api.truelayer.com"
  end

  # URL of TrueLayer's consent dialog for a new bank connection.
  def authorization_url(redirect_uri:, state:)
    query = {
      response_type: "code",
      client_id: client_id,
      scope: SCOPES,
      redirect_uri: redirect_uri,
      providers: PROVIDERS,
      prompt: "consent",
      state: state
    }
    "#{auth_base_url}/?#{URI.encode_www_form(query)}"
  end

  # Re-consent link for an existing connection (UK only). Keeps the same
  # TrueLayer account ids, so linked Sure accounts keep their history. Raises
  # TruelayerError when TrueLayer refuses (e.g. the refresh token has lapsed);
  # callers then fall back to #authorization_url.
  def reauthorization_url(refresh_token:, redirect_uri:, state:)
    response = with_retries("POST /v1/reauthuri") do
      self.class.post(
        "#{auth_base_url}/v1/reauthuri",
        headers: json_headers,
        body: { response_type: "code", refresh_token: refresh_token, redirect_uri: redirect_uri, state: state }.to_json
      )
    end
    body = handle_response(response, "POST /v1/reauthuri")
    url = body[:result].presence
    raise TruelayerError.new("TrueLayer returned no re-authorization URL", :fetch_failed) unless url

    url
  end

  # @return [Hash] { access_token:, refresh_token:, expires_in: }
  def exchange_code(code:, redirect_uri:)
    token_request(grant_type: "authorization_code", code: code, redirect_uri: redirect_uri)
  end

  # @return [Hash] { access_token:, refresh_token: (may be nil), expires_in: }
  def refresh_access_token(refresh_token)
    token_request(grant_type: "refresh_token", refresh_token: refresh_token)
  end

  # Connection metadata: provider, consent expiry. 403 means consent lapsed.
  def get_me(access_token)
    get(access_token, "/data/v1/me")[:results]&.first || {}
  end

  # The bank's current accounts, or nil when the provider has no accounts
  # endpoint (404/501), which is not the same as having none.
  def get_accounts(access_token)
    get(access_token, "/data/v1/accounts", missing_ok: true)&.then { |body| body[:results] || [] }
  end

  def get_cards(access_token)
    get(access_token, "/data/v1/cards", missing_ok: true)&.then { |body| body[:results] || [] }
  end

  # @param kind [String] "account" or "card"
  # @param from [Time] @param to [Time]
  def get_transactions(access_token, kind:, account_id:, from:, to:)
    query = URI.encode_www_form(from: from.utc.iso8601, to: to.utc.iso8601)
    get(access_token, "#{collection_path(kind, account_id)}/transactions?#{query}")[:results] || []
  end

  def get_balance(access_token, kind:, account_id:)
    get(access_token, "#{collection_path(kind, account_id)}/balance")[:results]&.first
  end

  class TruelayerError < StandardError
    attr_reader :error_type, :status, :code

    def initialize(message, error_type = :unknown, status: nil, code: nil)
      super(message)
      @error_type = error_type
      @status = status
      @code = code
    end

    # The connection cannot be used until the user consents again: the refresh
    # token is dead, the bank revoked access, or a token TrueLayer just issued
    # was refused. A first 401 is not included; the caller refreshes the access
    # token and retries once instead.
    def reauth_required?
      !history_refused? && error_type.in?(%i[consent_expired invalid_grant token_rejected])
    end

    # A transaction date range was declined, not the connection: the bank's
    # SCA exemption for older history has lapsed (403 sca_exceeded), or the
    # range is older than TrueLayer accepts (400 from the Data API).
    def history_refused?
      code == "sca_exceeded" || error_type == :bad_request
    end
  end

  private

    def collection_path(kind, account_id)
      collection = kind.to_s == "card" ? "cards" : "accounts"
      "/data/v1/#{collection}/#{ERB::Util.url_encode(account_id.to_s)}"
    end

    def token_request(**params)
      operation = "POST /connect/token (#{params[:grant_type]})"
      response = with_retries(operation, retries: 0) do
        self.class.post(
          "#{auth_base_url}/connect/token",
          headers: { "Content-Type" => "application/x-www-form-urlencoded", "Accept" => "application/json" },
          body: URI.encode_www_form(params.merge(client_id: client_id, client_secret: client_secret)),
          timeout: TOKEN_TIMEOUT
        )
      end

      body = parse_body(response)
      unless response.code == 200
        code = body[:error].to_s
        # invalid_grant: the refresh token or code is dead; a fresh consent is
        # needed. Anything else (invalid_client, 5xx) is configuration or transient.
        error_type = code == "invalid_grant" ? :invalid_grant : :token_failed
        raise TruelayerError.new(
          "TrueLayer token request failed (#{response.code}): #{body[:error_description].presence || code.presence || 'unknown error'}",
          error_type, status: response.code, code: code.presence
        )
      end

      {
        access_token: body[:access_token],
        refresh_token: body[:refresh_token].presence,
        expires_in: body[:expires_in].to_i
      }
    end

    def get(access_token, path, missing_ok: false)
      operation = "GET #{path.split('?').first}"
      response = with_retries(operation) do
        self.class.get("#{api_base_url}#{path}", headers: json_headers.merge("Authorization" => "Bearer #{access_token}"))
      end

      return nil if missing_ok && response.code.in?([ 404, 501 ])

      handle_response(response, operation)
    end

    def json_headers
      { "Content-Type" => "application/json", "Accept" => "application/json" }
    end

    def handle_response(response, operation)
      return parse_body(response) if response.code == 200

      body = parse_body(response)
      code = body[:error].presence&.to_s
      detail = body[:error_description].presence || body[:error_details].presence || code || response.message
      error_type = case response.code
      when 401 then :unauthorized
      when 403 then :consent_expired
      when 404 then :not_found
      when 429 then :rate_limited
      when 400..499 then :bad_request
      else :server_error
      end

      raise TruelayerError.new("TrueLayer #{operation} failed (#{response.code}): #{detail}", error_type, status: response.code, code: code)
    end

    def parse_body(response)
      parsed = JSON.parse(response.body.to_s, symbolize_names: true)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    # Retries network failures and transient 5xx responses. 429s are not retried:
    # unattended Open Banking access has a small daily quota per endpoint, and
    # retrying would only spend more of it.
    def with_retries(operation, retries: MAX_RETRIES)
      attempts = 0
      begin
        response = yield
        raise TruelayerError.new("TrueLayer #{operation} failed (#{response.code})", :server_error, status: response.code) if RETRYABLE_STATUSES.include?(response.code.to_i)

        response
      rescue *NETWORK_ERRORS, TruelayerError => e
        raise if e.is_a?(TruelayerError) && e.error_type != :server_error
        attempts += 1
        if attempts > retries
          raise e if e.is_a?(TruelayerError)
          raise TruelayerError.new("TrueLayer #{operation} failed: #{e.class.name}", :request_failed)
        end

        Rails.logger.warn("TrueLayer API: #{operation} failed (#{e.class.name}), retry #{attempts}/#{retries}")
        sleep(INITIAL_RETRY_DELAY * (2**(attempts - 1)))
        retry
      end
    end
end
