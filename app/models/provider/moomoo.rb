# moomoo OpenAPI client for the read-only trading endpoints.
#
# Sure registers a public OAuth client of its own for each connection (RFC 7591,
# no secret), bound to this instance's callback URL. The user signs in on
# moomoo's consent page and picks the scopes and trading accounts to share
# (OAuth 2.1 with PKCE S256). Access tokens last about two hours; refreshing
# does not rotate the refresh token.
#
# Trading responses are {"s":"ok","d":...} or {"s":"error","errcode":...}, and
# every trading timestamp is in Unix microseconds.
#
# Docs: https://open.moomoo.com/api/overview/getting-started
class Provider::Moomoo
  include HTTParty
  extend SslConfigurable

  headers "User-Agent" => "Sure Finance moomoo Client", "Accept" => "application/json"
  default_options.merge!({ timeout: 60 }.merge(httparty_ssl_options))

  BASE_URL = "https://webapi.moomoo.com".freeze
  # The browser consent page. /oauth2/authorize is moomoo's internal backend.
  AUTHORIZE_PATH = "/oauth2/authorize/confirm".freeze
  REGISTER_PATH = "/oauth2/register".freeze
  TOKEN_PATH = "/oauth2/token".freeze

  # Asked for at registration. The user still ticks scopes and accounts on the
  # consent page, which is what actually limits the token; moomoo documents
  # no scope parameter for that page.
  REGISTRATION_SCOPE = "trade:read accid:*".freeze
  REQUIRED_SCOPE = "trade:read".freeze
  # Lets a token place and cancel orders. Sure never trades, so a grant that
  # includes it is refused.
  ORDER_SCOPE = "trade:write".freeze

  # Token requests run under the item's row lock (MoomooItem#fresh_access_token),
  # so they get a short timeout and are never retried or delayed.
  TOKEN_TIMEOUT = 20
  DEFAULT_TOKEN_LIFETIME = 7200

  # moomoo allows 100 requests a minute per IP, which every sync on this
  # deployment shares. Each client spaces its own requests, and a count per
  # minute in the cache (Redis in production) keeps syncs running at once
  # under the limit together.
  MIN_REQUEST_INTERVAL = ENV.fetch("MOOMOO_MIN_REQUEST_INTERVAL", "0.7").to_f
  MAX_REQUESTS_PER_MINUTE = ENV.fetch("MOOMOO_MAX_REQUESTS_PER_MINUTE", "90").to_i
  MAX_RATE_LIMIT_RETRIES = 3
  MAX_RATE_LIMIT_WAIT = 60
  MAX_TRANSIENT_RETRIES = 2

  FILLS_PAGE_SIZE = 50
  TODAY_FILLS_PAGE_SIZE = 100
  ORDERS_PAGE_SIZE = 100
  CASH_LOGS_PAGE_SIZE = 20
  MAX_PAGES_PER_WINDOW = 40

  ERRCODE_TYPES = {
    -12006 => :unauthorized,
    -12009 => :scope_missing,
    -12011 => :rate_limited,
    -12102 => :token_expired,
    -12301 => :timeout
  }.freeze

  class MoomooError < StandardError
    # The connection stays unusable until the user consents again.
    REAUTH_TYPES = %i[invalid_grant invalid_client token_rejected scope_missing].freeze

    attr_reader :error_type, :status, :code

    def initialize(message, error_type = :unknown, status: nil, code: nil)
      super(message)
      @error_type = error_type
      @status = status
      @code = code
    end

    def reauth_required?
      error_type.in?(REAUTH_TYPES)
    end

    # The access token was refused: refresh it and retry once.
    def retry_with_fresh_token?
      error_type.in?(%i[token_expired unauthorized])
    end
  end

  # Caps the requests of one sync, retries and pages included, so a long
  # history backfill stops early and continues on the next sync.
  class RequestBudget
    attr_reader :limit, :used

    def initialize(limit)
      @limit = limit
      @used = 0
    end

    def remaining
      limit - used
    end

    def available?(count = 1)
      remaining >= count
    end

    def consume!
      raise MoomooError.new("moomoo request budget of #{limit} used up", :budget_exhausted) unless available?

      @used += 1
    end
  end

  class << self
    # RFC 7591 dynamic registration, which needs no credentials.
    # @return [Hash] { client_id:, registration_access_token:, registration_client_uri:, scope: }
    def register_client(redirect_uri:, client_name: "Sure")
      metadata = {
        redirect_uris: [ redirect_uri ],
        token_endpoint_auth_method: "none",
        grant_types: %w[authorization_code refresh_token],
        response_types: %w[code],
        client_name: client_name
      }

      # A scope at registration is not documented, nor how moomoo refuses one,
      # so any refusal of the scoped request falls back to the documented body,
      # and that request's outcome is the one reported.
      response = post_json(REGISTER_PATH, metadata.merge(scope: REGISTRATION_SCOPE))
      response = post_json(REGISTER_PATH, metadata) unless registered?(response)

      body = parse_body(response)
      unless registered?(response)
        detail = body["error_description"].presence || body["error"].presence || body["errmsg"].presence || "unexpected response"
        raise MoomooError.new(
          "moomoo client registration failed (#{response.code}): #{detail}",
          :registration_failed, status: response.code, code: body["error"].presence || body["errcode"]
        )
      end

      {
        client_id: body["client_id"].to_s,
        registration_access_token: body["registration_access_token"].presence,
        registration_client_uri: body["registration_client_uri"].presence,
        scope: body["scope"].presence
      }
    rescue *Provider::HttpTransport::TRANSPORT_ERRORS => e
      raise MoomooError.new("moomoo client registration failed: #{e.class.name}", :registration_failed)
    end

    def generate_pkce
      verifier = SecureRandom.urlsafe_base64(64).delete("=")[0, 128]
      challenge = Base64.urlsafe_encode64(OpenSSL::Digest::SHA256.digest(verifier), padding: false)
      { verifier: verifier, challenge: challenge }
    end

    def to_micros(time)
      (time.to_r * 1_000_000).to_i
    end

    def from_micros(value)
      micros = Integer(value, exception: false)
      return nil if micros.nil? || micros <= 0

      Time.zone.at(Rational(micros, 1_000_000))
    end

    def parse_body(response)
      parsed = JSON.parse(response.body.to_s)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    private
      def post_json(path, body)
        post("#{BASE_URL}#{path}", headers: { "Content-Type" => "application/json" }, body: body.to_json, timeout: TOKEN_TIMEOUT)
      end

      def registered?(response)
        response.code.in?([ 200, 201 ]) && parse_body(response)["client_id"].present?
      end
  end

  attr_reader :client_id, :budget

  def initialize(client_id:, budget: nil)
    raise MoomooError.new("moomoo client is not registered", :not_connected) if client_id.blank?

    @client_id = client_id
    @budget = budget
    @last_request_at = nil
  end

  def authorization_url(redirect_uri:, state:, code_challenge:)
    query = {
      client_id: client_id,
      code_challenge: code_challenge,
      code_challenge_method: "S256",
      redirect_uri: redirect_uri,
      response_type: "code",
      state: state
    }
    "#{BASE_URL}#{AUTHORIZE_PATH}?#{URI.encode_www_form(query)}"
  end

  # @return [Hash] { access_token:, refresh_token:, expires_in:, scope: }
  def exchange_code(code:, redirect_uri:, code_verifier:)
    token_request(grant_type: "authorization_code", code: code, client_id: client_id, redirect_uri: redirect_uri, code_verifier: code_verifier)
  end

  # moomoo keeps the refresh token, so refresh_token is normally nil here.
  def refresh_access_token(refresh_token)
    token_request(grant_type: "refresh_token", refresh_token: refresh_token, client_id: client_id)
  end

  # The trading accounts the user ticked on the consent page.
  def get_accounts(token)
    data = get(token, "/api/v1.0/accounts/authorized_trd_accs")
    Array(data.is_a?(Hash) ? data["accounts"] : nil)
  end

  # moomoo converts the account-wide figures into `currency`.
  def get_funds(token, acc_id:, currency:)
    data = get(token, "#{account_path(acc_id)}/funds", currency: currency)
    data.is_a?(Hash) ? data : {}
  end

  # Positions in every market of the account. `d` is a bare array here. Sure
  # closes the holdings a list leaves out, so an answer that isn't a list is
  # an error rather than an empty account.
  def get_positions(token, acc_id:)
    data = get(token, "#{account_path(acc_id)}/positions")
    return data if data.is_a?(Array)
    return data["positions"] if data.is_a?(Hash) && data["positions"].is_a?(Array)
    return [] if data.nil?

    raise MoomooError.new("moomoo GET #{label("#{account_path(acc_id)}/positions")} returned no position list", :api_error)
  end

  # Today's fills in one market, which fills_history may not list yet.
  def get_today_fills(token, acc_id:, trd_market:)
    paged(token, "#{account_path(acc_id)}/order_fills", "order_fills", trd_market: trd_market, page_size: TODAY_FILLS_PAGE_SIZE)
  end

  # Fills in one market whose update time falls in the window, as moomoo
  # documents it; moomoo SG lists fills without an update time.
  def get_fills_history(token, acc_id:, trd_market:, start_us:, end_us:)
    paged(token, "#{account_path(acc_id)}/fills_history", "order_fills",
          trd_market: trd_market, start: start_us, end: end_us, page_size: FILLS_PAGE_SIZE)
  end

  # Orders in one market created in the window.
  def get_orders_history(token, acc_id:, trd_market:, start_us:, end_us:)
    paged(token, "#{account_path(acc_id)}/orders_history", "orders",
          trd_market: trd_market, start: start_us, end: end_us, page_size: ORDERS_PAGE_SIZE)
  end

  # Cash movements in the window. Unlike the fills endpoints, the first page
  # is requested without a page_flag.
  def get_cash_logs(token, acc_id:, begin_us:, end_us:)
    paged(token, "#{account_path(acc_id)}/cash_logs", "cash_logs",
          first_flag: nil, begin_time: begin_us, end_time: end_us, page_size: CASH_LOGS_PAGE_SIZE)
  end

  private

    def account_path(acc_id)
      "/api/v1.0/accounts/#{ERB::Util.url_encode(acc_id.to_s)}"
    end

    # Follows page_flag until moomoo says the batch is complete. A page with no
    # rows does not end it: `completed` is the documented stop signal, and a
    # blank page_flag leaves nothing to follow. A page_flag already sent, or
    # MAX_PAGES_PER_WINDOW pages, stops the batch short.
    # @return [Hash] { records:, truncated:, reason: }
    def paged(token, path, key, first_flag: "", **query)
      records = []
      flag = first_flag
      seen_flags = Set.new

      MAX_PAGES_PER_WINDOW.times do
        data = get(token, path, **query, page_flag: flag)
        data = {} unless data.is_a?(Hash)
        records.concat(Array(data[key]))
        return { records: records, truncated: false } if data["completed"] == true

        next_flag = data["page_flag"].to_s
        return { records: records, truncated: false } if next_flag.blank?
        return { records: records, truncated: true, reason: :repeated_page_flag } if seen_flags.include?(next_flag)

        seen_flags << next_flag
        flag = next_flag
      end

      { records: records, truncated: true, reason: :page_limit }
    end

    # Every attempt, retries included, counts against the budget. Rate limits
    # wait for Retry-After; timeouts, 5xx and network failures are retried.
    def get(token, path, **query)
      rate_limit_retries = 0
      transient_retries = 0

      loop do
        budget&.consume!
        space_requests!

        response = nil
        error = begin
          response = self.class.get("#{BASE_URL}#{path}", headers: { "Authorization" => "Bearer #{token}" }, query: query.compact)
          return unwrap(response, path)
        rescue MoomooError => e
          e
        rescue *Provider::HttpTransport::TRANSPORT_ERRORS => e
          MoomooError.new("moomoo GET #{label(path)} failed: #{e.class.name}", :request_failed)
        end

        if error.error_type == :rate_limited && rate_limit_retries < MAX_RATE_LIMIT_RETRIES
          rate_limit_retries += 1
          wait = retry_after(response, rate_limit_retries)
          log_rate_limited(path, wait)
          sleep(wait)
        elsif error.error_type.in?(%i[timeout server_error request_failed]) && transient_retries < MAX_TRANSIENT_RETRIES
          transient_retries += 1
          log_retry(path, error.error_type, transient_retries)
          sleep(2**transient_retries)
        else
          raise error
        end
      end
    end

    # The envelope decides success: an error may come with HTTP 200.
    def unwrap(response, path)
      body = self.class.parse_body(response)
      return body["d"] if response.code == 200 && body["s"] == "ok"

      errcode = Integer(body["errcode"], exception: false) if body["errcode"].present?
      error_type = ERRCODE_TYPES[errcode] || error_type_for_status(response.code, body)
      raise MoomooError.new(
        "moomoo GET #{label(path)} failed (#{[ response.code, errcode ].compact.join(' / ')}): #{body['errmsg'].presence || 'unexpected response'}",
        error_type, status: response.code, code: errcode
      )
    end

    # A 403 without a moomoo body is more likely a proxy than a missing scope.
    def error_type_for_status(status, body)
      case status
      when 429 then :rate_limited
      when 401 then :token_expired
      when 403 then body.present? ? :scope_missing : :api_error
      when 500..599 then :server_error
      else :api_error
      end
    end

    def token_request(**params)
      response = self.class.post(
        "#{BASE_URL}#{TOKEN_PATH}",
        headers: { "Content-Type" => "application/x-www-form-urlencoded" },
        body: URI.encode_www_form(params),
        timeout: TOKEN_TIMEOUT
      )
      body = self.class.parse_body(response)

      if response.code == 200 && body["access_token"].present?
        return {
          access_token: body["access_token"].to_s,
          refresh_token: body["refresh_token"].presence,
          expires_in: body["expires_in"].to_i.nonzero? || DEFAULT_TOKEN_LIFETIME,
          scope: body["scope"].to_s
        }
      end

      oauth_error = body["error"].to_s
      errcode = Integer(body["errcode"], exception: false) if body["errcode"].present?
      detail = body["error_description"].presence || oauth_error.presence || body["errmsg"].presence || "unknown error"
      raise MoomooError.new(
        "moomoo token request (#{params[:grant_type]}) failed (#{response.code}): #{detail}",
        token_error_type(response.code, oauth_error, errcode), status: response.code, code: oauth_error.presence || errcode
      )
    rescue *Provider::HttpTransport::TRANSPORT_ERRORS => e
      raise MoomooError.new("moomoo token request (#{params[:grant_type]}) failed: #{e.class.name}", :token_failed)
    end

    # The token endpoint's error format is not documented. A bare 400 or 401
    # most likely means the code or refresh token is dead; 5xx, 429 and
    # network errors are transient.
    def token_error_type(status, oauth_error, errcode)
      if oauth_error == "invalid_client"
        :invalid_client
      elsif oauth_error.in?(%w[invalid_grant invalid_token unauthorized_client]) || errcode.in?([ -12006, -12102 ])
        :invalid_grant
      elsif status.in?([ 400, 401 ])
        :invalid_grant
      else
        :token_failed
      end
    end

    def space_requests!
      if @last_request_at
        wait = MIN_REQUEST_INTERVAL - (monotonic_now - @last_request_at)
        sleep(wait) if wait.positive?
      end
      take_shared_request_slot!
      @last_request_at = monotonic_now
    end

    # Counted before it is sent, so syncs that check at once can't both take
    # the last slot; one over the limit waits for the next minute and counts
    # there. Without a shared cache (or with Redis down) the count reads 0 and
    # only the spacing applies.
    def take_shared_request_slot!
      loop do
        count = Rails.cache.increment("moomoo:requests:#{Time.current.to_i / 60}", 1, expires_in: 2.minutes).to_i
        break if count <= MAX_REQUESTS_PER_MINUTE

        sleep(60 - (Time.current.to_i % 60) + 1)
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def retry_after(response, attempt)
      seconds = response&.headers&.[]("retry-after").to_i
      (seconds.positive? ? seconds : 2**attempt).clamp(1, MAX_RATE_LIMIT_WAIT)
    end

    # Request paths carry the trading account id, which stays out of logs.
    def label(path)
      path.sub(%r{/accounts/[^/]+}, "/accounts/:acc_id")
    end

    def log_retry(path, reason, attempt)
      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "Provider::Moomoo GET #{label(path)} attempt #{attempt} failed (#{reason}). Retrying",
        source: "moomoo",
        provider_key: "moomoo"
      )
    end

    def log_rate_limited(path, wait)
      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "Provider::Moomoo rate limited on GET #{label(path)}; waiting #{wait}s",
        source: "moomoo",
        provider_key: "moomoo",
        metadata: { retry_after: wait }
      )
    end
end
