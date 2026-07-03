# frozen_string_literal: true

# Wise personal API client.
#
# Auth model: Wise uses a long-lived personal API token generated once from
# Settings > API tokens. It does not rotate and has no expiry unless revoked
# by the user, so there is no token-refresh step.
#
# API structure:
#   1. GET /v1/profiles        -> list of personal/business profiles
#   2. GET /v3/profiles/{id}/balances?types=STANDARD -> per-currency balance jars
#   3. GET /v1/profiles/{id}/balance-statements/{balanceId}/statement.json
#      ?currency=USD&intervalStart=...&intervalEnd=... -> transactions
#
# Wise caps statement requests at ~469 days; we use 365-day windows.
class Provider::Wise
  include HTTParty

  headers "User-Agent" => "Sure Finance Wise Client"
  default_options.merge!(verify: true, ssl_verify_mode: OpenSSL::SSL::VERIFY_PEER, timeout: 120)

  BASE_URL            = "https://api.wise.com"
  MAX_STATEMENT_DAYS  = 365

  class Error < StandardError
    attr_reader :error_type

    def initialize(message, error_type = :unknown)
      super(message)
      @error_type = error_type
    end
  end

  class ConfigurationError < Error; end
  class AuthenticationError < Error; end
  class RetryableResponseError < Error; end

  attr_reader :api_token

  def initialize(api_token:)
    @api_token = api_token
    validate_configuration!
  end

  # GET /v1/profiles -> array of profile objects
  # Each profile: { id, type (personal|business), details: { firstName, lastName, ... } }
  def list_profiles
    get_json("v1/profiles")
  end

  # GET /v3/profiles/{profileId}/balances?types=STANDARD
  # Returns array: [{ id, type, name, amount: { value, currency }, currency, ... }]
  def list_balances(profile_id:)
    get_json("v3/profiles/#{profile_id}/balances", query: { types: "STANDARD" })
  end

  # GET /v1/profiles/{profileId}/balance-statements/{balanceId}/statement.json
  # Chunked into <=365-day windows because Wise's statement endpoint has a cap.
  # Returns merged array of transaction objects.
  def get_statement(profile_id:, balance_id:, currency:, start_date:, end_date: Date.current)
    transactions = []
    window_start = start_date.to_date
    end_date     = end_date.to_date

    while window_start <= end_date
      window_end = [ window_start + MAX_STATEMENT_DAYS - 1, end_date ].min

      page = get_json(
        "v1/profiles/#{profile_id}/balance-statements/#{balance_id}/statement.json",
        query: {
          currency:      currency,
          intervalStart: iso(window_start.beginning_of_day),
          intervalEnd:   iso(window_end.end_of_day)
        }
      )

      transactions.concat(Array(page.is_a?(Hash) ? page[:transactions] : page))
      window_start = window_end + 1
    end

    { transactions: transactions }
  end

  private

    RETRYABLE_ERRORS = [
      SocketError, Net::OpenTimeout, Net::ReadTimeout,
      Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ETIMEDOUT, EOFError
    ].freeze

    MAX_RETRIES          = 3
    INITIAL_RETRY_DELAY  = 2

    def validate_configuration!
      raise ConfigurationError.new("API token is required", :missing_credentials) if @api_token.blank?
    end

    def get_json(path, query: {})
      with_retries(path) do
        response = self.class.get("#{BASE_URL}/#{path}", headers: auth_headers, query: query)
        handle_response(response)
      end
    end

    def auth_headers
      {
        "Authorization" => "Bearer #{@api_token}",
        "Accept"        => "application/json"
      }
    end

    def iso(time)
      time.utc.iso8601
    end

    def with_retries(operation_name, max_retries: MAX_RETRIES)
      retries = 0

      begin
        yield
      rescue *RETRYABLE_ERRORS, RetryableResponseError => e
        retries += 1

        if retries <= max_retries
          delay = calculate_retry_delay(retries)
          Rails.logger.warn(
            "Wise API: #{operation_name} failed (attempt #{retries}/#{max_retries}): " \
            "#{e.class}: #{e.message}. Retrying in #{delay}s..."
          )
          sleep(delay)
          retry
        else
          Rails.logger.error(
            "Wise API: #{operation_name} failed after #{max_retries} retries: " \
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

    def capture_response_error(reason, response)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "error",
        message: "Wise API #{reason} (#{response.code})",
        source: self.class.name,
        provider_key: "wise",
        metadata: { status: response.code, body: response.body.to_s.first(1000) }
      )
    end

    def handle_response(response)
      case response.code
      when 200, 201
        JSON.parse(response.body, symbolize_names: true)
      when 400
        capture_response_error("bad_request", response)
        raise Error.new("Wise bad request (#{response.code})", :bad_request)
      when 401
        raise AuthenticationError.new("Invalid or revoked Wise API token", :unauthorized)
      when 403
        raise AuthenticationError.new("Wise access forbidden - check token permissions", :access_forbidden)
      when 404
        raise Error.new("Wise resource not found", :not_found)
      when 429
        raise RetryableResponseError.new("Wise rate limit exceeded. Please try again later.", :rate_limited)
      when 500..599
        raise RetryableResponseError.new("Wise server error (#{response.code}). Please try again later.", :server_error)
      else
        capture_response_error("unexpected_response", response)
        raise Error.new("Wise unexpected response (#{response.code})", :unknown)
      end
    end
end
