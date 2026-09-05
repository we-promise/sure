# API client for Monobank's personal (client) API — https://api.monobank.ua/docs.
#
# The personal API is deliberately small: one call returns the client's cards and jars,
# another returns a statement window for a single account. Both are documented as
# "не частіше ніж 1 раз у 60 секунд", per function, which shapes every caller: requests
# are throttled per endpoint (see #throttle_request) and a statement window may not
# exceed 31 days + 1 hour.
#
# Note on scope: Monobank's terms limit this token to personal use, so credentials are
# per-family (the user brings their own token from https://api.monobank.ua/) rather than
# a site-wide integration.
class Provider::Monobank < Provider
  include HTTParty
  include Provider::RateLimitable
  extend SslConfigurable

  # Subclass so errors caught in this provider are raised as Provider::Monobank::Error
  Error = Class.new(Provider::Error)
  class RateLimitError < Error; end

  DEFAULT_BASE_URL = "https://api.monobank.ua".freeze
  ALLOWED_HOST = URI.parse(DEFAULT_BASE_URL).host.freeze

  PROVIDER_ENV_PREFIX = "MONOBANK".freeze
  # Documented throttle for the personal endpoints: one request per minute, per function.
  MIN_REQUEST_INTERVAL = 60.0

  # Documented cap on a single statement request: 31 days + 1 hour.
  MAX_STATEMENT_WINDOW = 2_682_000

  # Undocumented but well-established cap on how many transactions one statement
  # response carries. Callers treat a full page as "possibly truncated" and continue
  # from the newest/oldest transaction they actually received rather than assuming the
  # whole window was covered.
  MAX_STATEMENT_ITEMS = 500

  headers "User-Agent" => "Sure Finance Monobank Client (https://github.com/we-promise/sure)"
  default_options.merge!({ timeout: 120 }.merge(httparty_ssl_options))

  attr_reader :access_token

  # Build a client with the family's Monobank personal token. Raises if blank.
  def initialize(access_token)
    @access_token = access_token.to_s.strip

    if @access_token.blank?
      raise Error.new("Monobank access token is required", failure_code: :configuration_error)
    end
  end

  # GET /personal/client-info — the client's profile plus every card and jar.
  # Doubles as the token check: an invalid token fails here with :unauthorized.
  def get_client_info
    payload = get("/personal/client-info", bucket: :client_info)

    unless payload.is_a?(Hash)
      raise Error.new("Unexpected Monobank client-info response", failure_code: :parse_error)
    end

    payload.with_indifferent_access
  end

  # Flattened account list built from client-info. Cards and jars are returned in one
  # array, each tagged with `kind` ("card" or "jar") so callers do not have to know
  # which half of the payload an account came from. Monobank's own field names are
  # preserved; only `kind` is added.
  #
  # @param client_info [Hash, nil] a previously fetched client-info payload, so a caller
  #   that already paid the rate-limited request can reuse it
  def get_accounts(client_info: nil)
    payload = (client_info || get_client_info).with_indifferent_access

    cards = Array(payload[:accounts]).filter_map { |account| flatten_account(account, kind: "card") }
    jars  = Array(payload[:jars]).filter_map { |jar| flatten_account(jar, kind: "jar") }

    cards + jars
  end

  # GET /personal/statement/{account}/{from}/{to} — transactions for one account or jar.
  # Both settled and held (pending) transactions are returned; callers derive pending
  # status from the `hold` field.
  #
  # @param account_id [String] Monobank account/jar id, or "0" for the default account
  # @param from [Time, Date, Integer] window start
  # @param to [Time, Date, Integer, nil] window end (defaults to now)
  # @raise [Error] when the requested window exceeds Monobank's 31-day cap, or when the
  #   response body is not the documented JSON array
  def get_statement(account_id:, from:, to: nil)
    from_unix = to_unix(from)
    to_unix_value = to.present? ? to_unix(to) : Time.current.to_i

    if to_unix_value < from_unix
      raise Error.new("Monobank statement window ends before it starts", failure_code: :bad_request)
    end

    if (to_unix_value - from_unix) > MAX_STATEMENT_WINDOW
      raise Error.new(
        "Monobank statement window exceeds the 31 day maximum",
        failure_code: :window_too_large
      )
    end

    path = "/personal/statement/#{ERB::Util.url_encode(account_id.to_s)}/#{from_unix}/#{to_unix_value}"
    transactions = get(path, bucket: :statement)

    # A statement is always a JSON array. Anything else (a 204, an empty body, an error
    # object) would otherwise read as "no activity in this window", and the caller would
    # record the window as permanently covered. Failing here leaves the cursors alone so
    # the window is walked again on the next sync.
    unless transactions.is_a?(Array)
      raise Error.new("Unexpected Monobank statement response", failure_code: :parse_error)
    end

    transactions.filter_map do |transaction|
      next unless transaction.is_a?(Hash)

      transaction.with_indifferent_access.merge(account_id: account_id.to_s)
    end
  end

  private

    RETRYABLE_ERRORS = [
      SocketError,
      Net::OpenTimeout,
      Net::ReadTimeout,
      Errno::ECONNRESET,
      Errno::ECONNREFUSED,
      Errno::ETIMEDOUT,
      EOFError
    ].freeze

    MAX_RETRIES = 3
    INITIAL_RETRY_DELAY = 2

    # Issues a throttled GET against the personal API. `bucket` names the rate-limit
    # bucket (see #throttle_request).
    def get(path, bucket:, query: nil)
      operation = "GET #{path}"

      with_retries(operation) do
        throttle_request(bucket)
        response = self.class.get(resolve_url(path), headers: auth_headers, query: query)
        handle_response(response, operation: operation)
      end
    end

    # Monobank documents its throttle per function, so client-info and statement each
    # get their own timer. Overrides Provider::RateLimitable's single-timer version
    # while still taking the interval (and its MONOBANK_MIN_REQUEST_INTERVAL override)
    # from the concern — a shared timer would add a needless minute to every sync.
    #
    # The timer lives on the instance: one client is built per sync, which is where
    # consecutive calls actually happen. Two syncs racing across processes can still
    # collide, and that surfaces as a :rate_limited error the importer treats as a
    # soft failure rather than a broken connection.
    def throttle_request(bucket = :default)
      @last_request_at ||= {}

      elapsed = Time.current - (@last_request_at[bucket] || Time.at(0))
      sleep_time = min_request_interval - elapsed
      sleep(sleep_time) if sleep_time > 0

      @last_request_at[bucket] = Time.current
    end

    # Normalizes a card or jar resource. Cards carry no display name of their own, so
    # naming is left to MonobankAccount (which localizes the card type); only the id,
    # `kind` tag and a jar's title are guaranteed here.
    def flatten_account(resource, kind:)
      return nil unless resource.is_a?(Hash)

      data = resource.with_indifferent_access
      return nil if data[:id].blank?

      data.merge(kind: kind)
    end

    # Resolves a relative path against the base URL, refusing to send the token
    # anywhere but Monobank's HTTPS host.
    def resolve_url(path)
      value = path.to_s
      return "#{DEFAULT_BASE_URL}#{value.start_with?('/') ? value : "/#{value}"}" unless value.start_with?("http")

      uri = URI.parse(value)
      unless uri.scheme == "https" && uri.host == ALLOWED_HOST
        raise Error.new("Refusing to send credentials to untrusted host: #{uri.host.inspect}", failure_code: :invalid_url)
      end

      value
    rescue URI::InvalidURIError
      raise Error.new("Invalid Monobank API URL", failure_code: :invalid_url)
    end

    # Monobank authenticates with a personal token in X-Token (not a bearer header).
    def auth_headers
      {
        "X-Token" => access_token,
        "Accept" => "application/json"
      }
    end

    # Converts a Time/Date/epoch into Unix seconds. A bare Date is read as UTC midnight
    # rather than in the server's zone, which would shift the window by the offset.
    def to_unix(value)
      # instance_of?, not is_a?: DateTime is a subclass of Date but only Date needs the
      # UTC-midnight reading, and DateTime#to_time takes no form argument.
      return value.to_time(:utc).to_i if value.instance_of?(Date)

      case value
      when Integer then value
      when Float then value.to_i
      when Time, DateTime then value.to_time.to_i
      when String then Time.parse(value).to_i
      else
        raise Error.new("Unsupported Monobank statement timestamp", failure_code: :bad_request)
      end
    rescue ArgumentError, TypeError
      raise Error.new("Unsupported Monobank statement timestamp", failure_code: :bad_request)
    end

    # Runs the block, retrying transient network errors with exponential backoff.
    def with_retries(operation_name, max_retries: MAX_RETRIES)
      retries = 0

      begin
        yield
      rescue *RETRYABLE_ERRORS => e
        retries += 1
        if retries <= max_retries
          delay = calculate_retry_delay(retries)
          capture_request_error(
            level: "warn",
            message: "Monobank API request will be retried",
            operation: operation_name,
            metadata: {
              error_class: e.class.name,
              retry_attempt: retries,
              retry_limit: max_retries,
              retry_delay: delay
            }
          )
          sleep(delay)
          retry
        end

        capture_request_error(
          level: "error",
          message: "Monobank API request failed after retries",
          operation: operation_name,
          metadata: { error_class: e.class.name, retry_limit: max_retries }
        )
        raise Error.new("Network error after #{max_retries} retries: #{e.message}", failure_code: :network_error)
      end
    end

    # Exponential backoff delay (with jitter), capped at 30 seconds.
    def calculate_retry_delay(retry_count)
      base_delay = INITIAL_RETRY_DELAY * (2 ** (retry_count - 1))
      jitter = base_delay * rand * 0.25
      [ base_delay + jitter, 30 ].min
    end

    # Maps an HTTP response to parsed data or a typed error by status code.
    def handle_response(response, operation: nil)
      case response.code
      when 200, 201
        parse_response_body(response, operation: operation)
      when 204
        {}
      when 400
        raise Error.new("Bad request to Monobank API (status=#{response.code})", failure_code: :bad_request)
      when 401
        raise Error.new("Invalid Monobank access token", failure_code: :unauthorized)
      when 403
        raise Error.new("Monobank access forbidden - check token permissions", failure_code: :access_forbidden)
      when 404
        raise Error.new("Monobank resource not found", failure_code: :not_found)
      when 429
        raise RateLimitError.new(
          "Monobank rate limit exceeded (one request per minute per endpoint)",
          failure_code: :rate_limited
        )
      when 500..599
        raise Error.new("Monobank server error (#{response.code}). Please try again later.", failure_code: :server_error)
      else
        capture_request_error(
          level: "error",
          message: "Monobank API returned an unexpected response status",
          operation: operation,
          metadata: { status: response.code }
        )
        raise Error.new("Failed to fetch Monobank data", failure_code: :fetch_failed)
      end
    end

    # Parses a JSON response body, raising a typed error on malformed JSON.
    def parse_response_body(response, operation: nil)
      return {} if response.body.blank?

      JSON.parse(response.body)
    rescue JSON::ParserError
      capture_request_error(
        level: "error",
        message: "Monobank API response could not be parsed",
        operation: operation,
        metadata: { status: response.code, body_bytes: response.body.bytesize }
      )
      raise Error.new("Failed to parse Monobank API response", failure_code: :parse_error)
    end

    # Transport-level diagnostics for /settings/debug. The client is built from a token
    # alone, so it has no family or account_provider to attach — MonobankItem::Importer
    # catches the typed error these paths raise and records the same failure against the
    # connection. What only exists here is the transport detail (status, retry attempt),
    # which never reaches that layer, so it is captured here rather than left in the
    # application log. The body is never included: it carries statement PII.
    def capture_request_error(level:, message:, operation:, metadata: {})
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: level,
        message: message,
        source: self.class.name,
        provider_key: "monobank",
        metadata: metadata.merge(operation: operation).compact
      )
    end
end
