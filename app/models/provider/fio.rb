# frozen_string_literal: true

# Client for Fio banka's "API Bankovnictví" (v1.9, https://www.fio.cz/docs/cz/API_Bankovnictvi.pdf).
#
# Two properties of this API shape everything above it:
#
#   * A token grants access to exactly **one** account, and there is no endpoint that
#     lists accounts. The statement header (`accountStatement.info`) *is* the account
#     description, so a fetch doubles as account discovery.
#   * A token may be used **once per 30 seconds**, for reading or writing, regardless of
#     format. Exceeding that is HTTP 409. One statement request per sync therefore is not
#     an optimisation but the design constraint.
#
# The token travels in the URL path, not a header. Nothing here may put a resolved URL
# into an exception message, a log line or debug metadata.
class Provider::Fio < Provider
  include HTTParty
  extend SslConfigurable

  # Subclass so errors caught in this provider are raised as Provider::Fio::Error
  Error = Class.new(Provider::Error)
  # 409: the 30-second interval was not respected. Nothing to do but sync again later.
  class RateLimitError < Error; end
  # 422: the requested range reaches further back than 90 days and the account's full
  # history has not been unlocked in internet banking.
  class HistoryLockedError < Error; end
  # 413: more than 50 000 movements in the requested range.
  class TooManyItemsError < Error; end

  DEFAULT_BASE_URL = "https://fioapi.fio.cz/v1/rest".freeze
  ALLOWED_HOST = URI.parse(DEFAULT_BASE_URL).host.freeze

  # Days of history reachable without a temporary unlock in internet banking.
  UNAUTHORIZED_HISTORY_DAYS = 90

  # Documented minimum interval between two uses of one token. Enforced by Fio, not here:
  # a sleeping client-side timer would have to outlive the job to be of any use, and a
  # sync only ever spends one request. Callers treat RateLimitError as "try next sync".
  MIN_REQUEST_INTERVAL = 30.0

  headers "User-Agent" => "Sure Finance Fio Client (https://github.com/we-promise/sure)"
  default_options.merge!({ timeout: 120 }.merge(httparty_ssl_options))

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
  INITIAL_RETRY_DELAY = 2 # seconds

  attr_reader :token

  def initialize(token)
    @token = token.to_s.strip

    if @token.blank?
      raise Error.new("Fio token is required", failure_code: :configuration_error)
    end
  end

  # Movements booked between `from` and `to`, with the statement header describing the
  # account the token belongs to.
  #
  # Both bounds are inclusive banking days. Unlike `/last/`, this endpoint does not touch
  # the server-side download marker ("zarážka"), so a failed or partial import can simply
  # be repeated — the caller keeps its own cursor.
  #
  # @param from [Date] first booking day to include
  # @param to [Date] last booking day to include
  # @return [Hash] the `accountStatement` object: `"info"` plus `"transactionList"`
  def get_statement(from:, to: Date.current)
    from_date = to_date(from)
    to_date_value = to_date(to)

    if from_date > to_date_value
      raise Error.new("Fio statement range ends before it starts", failure_code: :bad_request)
    end

    body = get("periods/#{path_segment(from_date)}/#{path_segment(to_date_value)}/transactions.json",
               operation: "GET periods")

    # A range with no movements can answer 200 with an empty body rather than a header
    # and an empty transactionList.
    return {}.with_indifferent_access if body.blank?

    statement = body.is_a?(Hash) ? body["accountStatement"] : nil

    unless statement.is_a?(Hash)
      capture_request_error(
        level: "error",
        message: "Fio statement response had no accountStatement object",
        operation: "GET periods"
      )
      raise Error.new("Unexpected Fio statement response", failure_code: :parse_error)
    end

    statement.with_indifferent_access
  end

  private

    # Builds the token-bearing URL and performs the request. `operation` is a static
    # label: it reaches diagnostics, so it must never carry the path.
    def get(path, operation:)
      with_retries(operation) do
        response = self.class.get(resolve_url(path), headers: request_headers)
        handle_response(response, operation: operation)
      end
    end

    # Resolves a relative path against the base URL, refusing to send the token anywhere
    # but Fio's HTTPS host.
    def resolve_url(path)
      "#{DEFAULT_BASE_URL}/#{token}/#{path}".tap do |url|
        uri = URI.parse(url)
        unless uri.scheme == "https" && uri.host == ALLOWED_HOST
          raise Error.new("Refusing to send credentials to untrusted host", failure_code: :invalid_url)
        end
      end
    rescue URI::InvalidURIError
      raise Error.new("Invalid Fio API URL", failure_code: :invalid_url)
    end

    def request_headers
      { "Accept" => "application/json" }
    end

    def path_segment(date)
      date.strftime("%Y-%m-%d")
    end

    def to_date(value)
      case value
      when Date then value
      when Time, DateTime then value.to_date
      when String then Date.parse(value)
      else
        raise Error.new("Unsupported Fio statement date", failure_code: :bad_request)
      end
    rescue ArgumentError, TypeError
      raise Error.new("Unsupported Fio statement date", failure_code: :bad_request)
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
            category: "provider_sync",
            level: "warn",
            message: "Fio API request will be retried",
            operation: operation_name,
            metadata: {
              error_class: e.class.name,
              retry_attempt: retries,
              retry_limit: max_retries,
              retry_delay: delay.round(2)
            }
          )
          Rails.logger.warn(
            "Fio API: #{operation_name} failed (attempt #{retries}/#{max_retries}): " \
            "#{e.class}. Retrying in #{delay.round(2)}s..."
          )
          sleep(delay)
          retry
        end

        capture_request_error(
          level: "error",
          message: "Fio API request failed after retries",
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

    # Maps an HTTP response to parsed data or a typed error. Status codes follow section 8
    # of the API documentation and are mostly not what their HTTP meaning suggests: 500 is
    # an unknown or expired token, and 404 is a malformed request rather than a missing
    # account.
    def handle_response(response, operation: nil)
      case response.code
      when 200, 201
        parse_response_body(response, operation: operation)
      when 204
        {}
      when 404
        raise Error.new("Fio rejected the request URL", failure_code: :bad_request)
      when 409
        raise RateLimitError.new(
          "Fio allows one request per 30 seconds per token",
          failure_code: :rate_limited
        )
      when 413
        raise TooManyItemsError.new(
          "Fio statement exceeds the 50 000 movement limit for one request",
          failure_code: :too_many_items
        )
      when 422
        raise HistoryLockedError.new(
          "Fio movements older than #{UNAUTHORIZED_HISTORY_DAYS} days need the account's " \
          "full history unlocked in internet banking",
          failure_code: :history_locked
        )
      when 500
        # Documented as "nonexistent or inactive token", which is an authorization
        # failure the user has to fix, not a transient server fault.
        raise Error.new("Fio token is unknown or no longer valid", failure_code: :unauthorized)
      when 501..599
        raise Error.new("Fio server error (#{response.code}). Please try again later.", failure_code: :server_error)
      else
        capture_request_error(
          level: "error",
          message: "Fio API returned an unexpected response status",
          operation: operation,
          metadata: { status: response.code }
        )
        raise Error.new("Failed to fetch Fio data", failure_code: :fetch_failed)
      end
    end

    def parse_response_body(response, operation: nil)
      # A statement request whose range contains no movements answers 200 with an empty
      # body rather than an empty transactionList.
      return {} if response.body.blank?

      JSON.parse(response.body)
    rescue JSON::ParserError
      capture_request_error(
        level: "error",
        message: "Fio API response could not be parsed",
        operation: operation,
        metadata: { status: response.code, body_bytes: response.body.bytesize }
      )
      raise Error.new("Failed to parse Fio API response", failure_code: :parse_error)
    end

    # Transport-level diagnostics for /settings/debug. The client is built from a token
    # alone, so it has no family or account_provider to attach — FioItem::Importer records
    # the same failure against the connection. Neither the URL (it contains the token) nor
    # the body (statement PII) is ever included.
    def capture_request_error(level:, message:, operation:, category: "provider_sync_error", metadata: {})
      DebugLogEntry.capture(
        category: category,
        level: level,
        message: message,
        source: self.class.name,
        provider_key: "fio",
        metadata: metadata.merge(operation: operation).compact
      )
    end
end
