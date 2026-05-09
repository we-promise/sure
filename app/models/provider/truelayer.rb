class Provider::Truelayer
  include HTTParty
  extend SslConfigurable

  Error = Class.new(Provider::Error)

  class RateLimitError < Error
    attr_reader :retry_after

    def initialize(retry_after: nil)
      super("TrueLayer rate limit exceeded")
      @retry_after = retry_after
    end
  end

  PRODUCTION_API  = "https://api.truelayer.com".freeze
  PRODUCTION_AUTH = "https://auth.truelayer.com".freeze
  SANDBOX_API     = "https://api.truelayer-sandbox.com".freeze
  SANDBOX_AUTH    = "https://auth.truelayer-sandbox.com".freeze

  MAX_RETRIES = 3
  MAX_RETRY_AFTER_SECONDS = 30

  headers "User-Agent" => "Sure Finance TrueLayer Client"
  default_options.merge!({ timeout: 120 }.merge(httparty_ssl_options))

  TokenResponse = Struct.new(:access_token, :refresh_token, :expires_in, keyword_init: true)

  # Wrap any HTTP POST so that socket/timeout failures surface as TransientError —
  # matches the GET path in #with_rate_limit_retry. Without this, OAuth flows
  # raise raw Net errors on provider-side blips and the caller has no signal to
  # treat them as retryable.
  def self.with_transient_classification
    yield
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    raise Provider::Auth::TransientError, "TrueLayer request failed: #{e.message}"
  end

  # Handles OAuth2 token exchange and refresh.
  # Instantiated by Provider::Auth::OAuth2 via adapter_config.token_client(family_credentials).
  class TokenClient
    def initialize(credentials, sandbox: false)
      @credentials = credentials
      @sandbox     = sandbox
    end

    def exchange(code:, redirect_uri:)
      response = Provider::Truelayer.with_transient_classification do
        Provider::Truelayer.post(
          "#{auth_base}/connect/token",
          headers: { "Content-Type" => "application/x-www-form-urlencoded" },
          body: {
            grant_type:    "authorization_code",
            client_id:     @credentials[:client_id],
            client_secret: @credentials[:client_secret],
            code:          code,
            redirect_uri:  redirect_uri
          }
        )
      end
      parse_token_response(response)
    end

    def refresh(refresh_token)
      response = Provider::Truelayer.with_transient_classification do
        Provider::Truelayer.post(
          "#{auth_base}/connect/token",
          headers: { "Content-Type" => "application/x-www-form-urlencoded" },
          body: {
            grant_type:    "refresh_token",
            client_id:     @credentials[:client_id],
            client_secret: @credentials[:client_secret],
            refresh_token: refresh_token
          }
        )
      end
      parse_token_response(response)
    end

    private

      def parse_token_response(response)
        case response.code
        when 200
          data = JSON.parse(response.body)
          TokenResponse.new(
            access_token:  data["access_token"],
            refresh_token: data["refresh_token"],
            expires_in:    data["expires_in"].to_i
          )
        when 400
          body = safe_parse(response.body)
          raise Provider::Auth::ConsentExpiredError if body["error"] == "invalid_grant"
          raise Provider::Truelayer::Error, body["error_description"] || "Token request failed"
        when 500..599
          raise Provider::Auth::TransientError, "TrueLayer auth #{response.code}"
        else
          raise Provider::Truelayer::Error, "TrueLayer auth error #{response.code}"
        end
      end

      def auth_base
        @sandbox ? SANDBOX_AUTH : PRODUCTION_AUTH
      end

      def safe_parse(body)
        JSON.parse(body)
      rescue JSON::ParserError
        {}
      end
  end

  def self.token_client(credentials, sandbox: false)
    TokenClient.new(credentials, sandbox: sandbox)
  end

  def self.reauth_uri(refresh_token:, redirect_uri:, state:, client_id:, client_secret:, sandbox: false)
    auth_base = sandbox ? SANDBOX_AUTH : PRODUCTION_AUTH
    response = with_transient_classification do
      post(
        "#{auth_base}/v1/reauthuri",
        headers: { "Content-Type" => "application/json" },
        body: {
          response_type:  "code",
          client_id:      client_id,
          client_secret:  client_secret,
          refresh_token:  refresh_token,
          redirect_uri:   redirect_uri,
          state:          state
        }.to_json
      )
    end

    case response.code
    when 200..299
      body = JSON.parse(response.body) rescue {}
      body["result"]
    when 429, 500..599
      raise Provider::Auth::TransientError, "TrueLayer reauth #{response.code}"
    else
      body = JSON.parse(response.body) rescue {}
      raise Provider::Truelayer::Error, body["error_description"] || "Reauth URI request failed (#{response.code})"
    end
  end

  def initialize(access_token, psu_ip: nil, sandbox: false)
    @access_token = access_token
    @psu_ip       = psu_ip
    @sandbox      = sandbox
  end

  def me
    get("/data/v1/me")
  end

  def get_accounts
    get("/data/v1/accounts")["results"] || []
  end

  def get_cards
    get("/data/v1/cards")["results"] || []
  end

  # kind: "account" or "card" — routes to the correct TrueLayer endpoint.
  def get_balance(account_id, kind: "account")
    path = kind == "card" ? "/data/v1/cards/#{account_id}/balance" : "/data/v1/accounts/#{account_id}/balance"
    get(path)["results"]&.first
  end

  def get_transactions(account_id, kind: "account", from: 90.days.ago, to: Time.current)
    path = kind == "card" ? "/data/v1/cards/#{account_id}/transactions" : "/data/v1/accounts/#{account_id}/transactions"
    get(path, query: { from: from.iso8601, to: to.iso8601 })["results"] || []
  end

  def get_pending_transactions(account_id, kind: "account")
    path = kind == "card" ? "/data/v1/cards/#{account_id}/transactions/pending" : "/data/v1/accounts/#{account_id}/transactions/pending"
    get(path)["results"] || []
  end

  private

    def get(path, query: {})
      with_rate_limit_retry do
        response = self.class.get(
          "#{api_base}#{path}",
          query:   query.presence,
          headers: request_headers
        )
        handle_response(response)
      end
    end

    def handle_response(response)
      case response.code
      when 200, 201
        parse_body(response)
      when 400
        body = safe_parse(response.body)
        raise Provider::Auth::ConsentExpiredError if body["error"] == "invalid_grant"
        raise Error, body["error_description"] || "Bad request"
      when 401, 403
        raise Provider::Auth::ReauthRequiredError
      when 404
        raise Error, "Resource not found"
      when 429
        raise RateLimitError.new(retry_after: response.headers["Retry-After"].to_i)
      when 501
        raise Error, "Endpoint not supported by this bank"
      when 500..599
        raise Provider::Auth::TransientError, "TrueLayer API #{response.code}"
      else
        raise Error, "TrueLayer API error #{response.code}"
      end
    end

    def parse_body(response)
      return {} if response.body.blank?
      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise Error, "Failed to parse response: #{e.message}"
    end

    def with_rate_limit_retry(max_retries: MAX_RETRIES)
      attempts = 0
      begin
        yield
      rescue RateLimitError => e
        attempts += 1
        raise if attempts > max_retries
        wait = [ e.retry_after.to_i, MAX_RETRY_AFTER_SECONDS ].min
        sleep(wait) if wait > 0
        retry
      rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
        raise Provider::Auth::TransientError, "TrueLayer request failed: #{e.message}"
      end
    end

    def request_headers
      headers = {
        "Authorization" => "Bearer #{@access_token}",
        "Accept"        => "application/json"
      }
      headers["X-PSU-IP"] = @psu_ip if @psu_ip.present?
      headers
    end

    def api_base = @sandbox ? SANDBOX_API : PRODUCTION_API

    def safe_parse(body)
      JSON.parse(body)
    rescue JSON::ParserError
      {}
    end
end
