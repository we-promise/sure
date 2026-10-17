# frozen_string_literal: true

class Provider::Wise
  include HTTParty
  extend SslConfigurable

  LIVE_BASE_URL = "https://api.wise.com"
  SANDBOX_BASE_URL = "https://api.wise-sandbox.com"
  # Wise caps a single balance-statement request at 469 days; chunk at 468 to
  # stay safely within the limit while covering the full requested range.
  MAX_STATEMENT_DAYS = 468
  # A request that may succeed later (WiseError#retryable?) is retried this
  # many times, never waiting longer than RETRY_MAX_WAIT seconds between
  # attempts.
  RETRIES = 3
  RETRY_MAX_WAIT = 60

  headers "User-Agent" => "Sure Finance Wise Client"
  default_options.merge!({ timeout: 120 }.merge(httparty_ssl_options))

  # Wise header carrying the one-time-token challenge on a 403 that requires
  # Strong Customer Authentication (SCA), and the header used to submit the
  # signed response.
  SCA_CHALLENGE_HEADER = "x-2fa-approval"
  SCA_SIGNATURE_HEADER = "X-Signature"

  attr_reader :token, :base_url, :sca_private_key

  # Runs the block, retrying a request Wise rate-limited (429), answered with
  # a server error (5xx), or that failed on the way (a timeout, a refused
  # connection). Each wait follows Wise's Retry-After when it is longer than
  # the exponential backoff (2, 4, 8 s) and adds up to a second of jitter. A
  # Retry-After beyond RETRY_MAX_WAIT is not waited out: an earlier attempt
  # would be refused too, so the error is raised and the next sync tries again.
  def self.with_retries(max_retries: RETRIES)
    retries = 0
    begin
      yield
    rescue WiseError => e
      raise unless e.retryable? && retries < max_retries && e.retry_after.to_f <= RETRY_MAX_WAIT

      retries += 1
      sleep([ [ e.retry_after.to_f, 2**retries ].max + rand, RETRY_MAX_WAIT ].min)
      retry
    end
  end

  def initialize(token, base_url: LIVE_BASE_URL, sca_private_key: nil)
    @token = token
    @base_url = base_url
    @sca_private_key = sca_private_key
  end

  def get_me
    get("/v1/me")
  end

  def get_profiles
    get("/v1/profiles")
  end

  def get_balances(profile_id)
    get("/v4/profiles/#{profile_id}/balances", query: { types: "STANDARD" })
  end

  def get_savings_balances(profile_id)
    get("/v4/profiles/#{profile_id}/balances", query: { types: "SAVINGS" })
  end

  def get_balance_statement(profile_id, balance_id, interval_start:, interval_end:, currency: nil)
    get(
      "/v1/profiles/#{profile_id}/balance-statements/#{balance_id}/statement.json",
      query: {
        currency: currency,
        intervalStart: interval_start.to_time.utc.iso8601,
        intervalEnd: interval_end.to_time.utc.iso8601
      }
    )
  end

  # The statement rows between two instants, which Wise reads as UTC (so a
  # window starts at the moment given, not at midnight in whatever zone the
  # job runs in). Longer intervals are asked for in windows of
  # MAX_STATEMENT_DAYS, each retried on its own (.with_retries) so earlier
  # windows are not fetched again.
  def get_balance_statements(profile_id, balance_id, currency:, interval_start:, interval_end: Time.current)
    transactions = []
    window_start = interval_start.to_time.utc
    finish = interval_end.to_time.utc
    return transactions if window_start > finish

    loop do
      window_end = [ window_start + MAX_STATEMENT_DAYS.days, finish ].min
      response = self.class.with_retries do
        get_balance_statement(profile_id, balance_id, currency: currency, interval_start: window_start, interval_end: window_end)
      end
      transactions.concat(Array(response["transactions"] || response[:transactions]))
      break if window_end >= finish

      window_start = window_end
    end

    transactions
  end

  # Wise lists transfers oldest first. createdDateStart/createdDateEnd are
  # inclusive dates, sent as the UTC date of the given time. The offset
  # must be a multiple of the limit (HTTP 422 inconsistent.pagination).
  def get_transfers(profile_id, limit: 100, offset: 0, created_date_start: nil, created_date_end: nil)
    query = { profile: profile_id, limit: limit, offset: offset }
    query[:createdDateStart] = utc_date(created_date_start) if created_date_start
    query[:createdDateEnd] = utc_date(created_date_end) if created_date_end
    get("/v1/transfers", query: query)
  end

  def get_transfer(transfer_id)
    get("/v1/transfers/#{transfer_id}")
  end

  # Wise lists activities newest first. The next page is requested with the
  # previous response's `cursor` as `nextCursor` (a `cursor` parameter is
  # ignored and returns the first page again); since/until are UTC instants.
  def get_activities(profile_id, cursor: nil, size: 100, since: nil, until_time: nil)
    query = { size: size }
    query[:nextCursor] = cursor if cursor
    query[:since] = since.to_time.utc.iso8601 if since
    query[:until] = until_time.to_time.utc.iso8601 if until_time
    get("/v1/profiles/#{profile_id}/activities", query: query)
  end

  # The account recipient (`recipientId`, the target of transfers into the
  # account) and the account's `creationTime`.
  def get_multi_currency_account(profile_id)
    get("/v4/profiles/#{profile_id}/multi-currency-account")
  end

  def get_borderless_accounts(profile_id)
    get("/v1/borderless-accounts", query: { profileId: profile_id })
  end

  private

    def get(path, query: {}, sca_headers: {})
      response = self.class.get(
        "#{base_url}#{path}",
        headers: auth_headers.merge(sca_headers),
        query: query.presence
      )

      if sca_retry?(response, already_retried: sca_headers.present?)
        return get(path, query: query, sca_headers: sca_approval_headers(response))
      end

      handle_response(response, sca_challenged: sca_headers.present? || sca_challenge_token(response).present?)
    rescue WiseError
      raise
    rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
      raise WiseError.new("Connection failed: #{e.message}", :request_failed)
    rescue => e
      raise WiseError.new("Unexpected error: #{e.message}", :request_failed)
    end

    # Wise's balance-statement endpoint (and other sensitive endpoints) require
    # Strong Customer Authentication: a 403 carrying a one-time-token challenge
    # in SCA_CHALLENGE_HEADER, which must be signed with an RSA private key the
    # user has registered with Wise and echoed back on a retry. Retries at most
    # once per request to avoid looping if the key is missing or rejected.
    def sca_retry?(response, already_retried:)
      return false if already_retried
      return false unless response.code == 403
      sca_private_key.present? && sca_challenge_token(response).present?
    end

    def sca_challenge_token(response)
      response.headers[SCA_CHALLENGE_HEADER]
    end

    def sca_approval_headers(response)
      challenge = sca_challenge_token(response)
      { SCA_CHALLENGE_HEADER => challenge, SCA_SIGNATURE_HEADER => sign_sca_challenge(challenge) }
    end

    def sign_sca_challenge(challenge)
      key = OpenSSL::PKey::RSA.new(sca_private_key)
      Base64.strict_encode64(key.sign(OpenSSL::Digest::SHA256.new, challenge))
    rescue OpenSSL::PKey::RSAError => e
      raise WiseError.new("Invalid SCA private key: #{e.message}", :sca_key_invalid)
    end

    def auth_headers
      {
        "Authorization" => "Bearer #{token}",
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }
    end

    def handle_response(response, sca_challenged: false)
      case response.code
      when 200
        JSON.parse(response.body)
      when 401
        raise WiseError.new("Invalid API token", :unauthorized)
      when 403
        raise WiseError.new("Access forbidden — check token permissions", :access_forbidden, sca_challenged: sca_challenged)
      when 404
        raise WiseError.new("Resource not found", :not_found)
      when 429
        raise WiseError.new("Rate limit exceeded. Please try again later.", :rate_limited, retry_after: retry_after_seconds(response))
      else
        error_type = response.code.to_i.between?(500, 599) ? :server_error : :fetch_failed
        raise WiseError.new("Unexpected response #{response.code}: #{response.body}", error_type)
      end
    end

    # Wise sends Retry-After as a number of seconds.
    def retry_after_seconds(response)
      seconds = Integer(response.headers&.[]("Retry-After").to_s, exception: false)
      seconds if seconds&.positive?
    end

    def utc_date(value)
      date = value.is_a?(Date) && !value.is_a?(DateTime) ? value : value.to_time.utc.to_date
      date.iso8601
    end

    private

      class WiseError < StandardError
        attr_reader :error_type, :retry_after

        def initialize(message, error_type = :unknown, retry_after: nil, sca_challenged: false)
          super(message)
          @error_type = error_type
          @retry_after = retry_after
          @sca_challenged = sca_challenged
        end

        # A 403 that carried Wise's one-time-token challenge (or answered a
        # signed retry) needs a registered SCA key. A 403 without one means
        # the token may not use the endpoint at all.
        def sca_challenged?
          @sca_challenged
        end

        # Asking again later may succeed (Provider::Wise.with_retries).
        def retryable?
          %i[rate_limited server_error request_failed].include?(error_type)
        end
      end
end
