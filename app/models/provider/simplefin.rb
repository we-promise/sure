require "bigdecimal"

class Provider::Simplefin
  # Pending: some institutions do not return pending transactions even with `pending=1`.
  # This is provider variability (not a bug). The importer resolves pending inclusion
  # from its explicit argument, SIMPLEFIN_INCLUDE_PENDING, or Setting.syncs_include_pending
  # (default-on without overrides), then passes pending: to this client.
  # SIMPLEFIN_DEBUG_RAW=1 enables raw payload logging (default-off); environment
  # configuration lives in config/initializers/simplefin.rb.
  include HTTParty
  extend SslConfigurable

  headers "User-Agent" => "Sure Finance SimpleFin Client"
  default_options.merge!({ timeout: 120 }.merge(httparty_ssl_options))

  # Retry configuration for transient network failures
  MAX_RETRIES = 3
  INITIAL_RETRY_DELAY = 2 # seconds
  MAX_RETRY_DELAY = 30 # seconds

  # Errors that are safe to retry (transient network issues)
  RETRYABLE_ERRORS = [
    SocketError,
    Net::OpenTimeout,
    Net::ReadTimeout,
    Errno::ECONNRESET,
    Errno::ECONNREFUSED,
    Errno::ETIMEDOUT,
    EOFError
  ].freeze

  def initialize
  end

  def claim_access_url(setup_token)
    # Decode the base64 setup token to get the claim URL
    claim_url = Base64.decode64(setup_token)

    # A timeout/reset can occur after the server consumes this single-use token.
    # Neither our wrapper nor the HTTP transport may replay the claim.
    # Use self.class.post to inherit class-level SSL and timeout defaults
    response = with_retries("POST /claim", max_retries: 0, backoff: false, redact_errors: true) do
      self.class.post(claim_url, timeout: 15, max_retries: 0)
    end

    case response.code
    when 200
      # The response body contains the access URL with embedded credentials
      response.body.strip
    when 403
      raise SimplefinError.new("Setup token may be compromised, expired, or already used", :token_compromised)
    else
      raise SimplefinError.new("Failed to claim access URL (HTTP #{response.code})", :claim_failed)
    end
  end

  def get_accounts(access_url, start_date: nil, end_date: nil, pending: nil)
    # Build query parameters
    query_params = {}

    # SimpleFin expects Unix timestamps for dates
    if start_date
      start_timestamp = start_date.to_time.to_i
      query_params["start-date"] = start_timestamp.to_s
    end

    if end_date
      end_timestamp = end_date.to_time.to_i
      query_params["end-date"] = end_timestamp.to_s
    end

    # Per the SimpleFIN protocol, pending transactions are excluded by default
    # and only included when `pending=1` is present. Bridges presence-check the
    # param, so sending `pending=0` behaves like `pending=1` — the only
    # spec-compliant way to exclude pending is to omit the param entirely.
    query_params["pending"] = "1" if pending

    accounts_url = "#{access_url}/accounts"
    accounts_url += "?#{URI.encode_www_form(query_params)}" unless query_params.empty?

    # The access URL already contains HTTP Basic Auth credentials
    # Use retry logic with exponential backoff for transient network failures
    # Use self.class.get to inherit class-level SSL and timeout defaults
    response = with_retries("GET /accounts") do
      self.class.get(accounts_url)
    end

    case response.code
    when 200
      JSON.parse(response.body, symbolize_names: true)
    when 400
      Rails.logger.error "SimpleFin API: Bad request - #{response.body}"
      raise SimplefinError.new("Bad request to SimpleFin API: #{response.body}", :bad_request)
    when 403
      raise SimplefinError.new("Access URL is no longer valid", :access_forbidden)
    when 402
      raise SimplefinError.new("Payment required to access this account", :payment_required)
    when 429
      Rails.logger.warn "SimpleFin API: Rate limited - #{response.body}"
      raise SimplefinError.new("SimpleFin rate limit exceeded. Please try again later.", :rate_limited)
    when 500..599
      Rails.logger.error "SimpleFin API: Server error - Code: #{response.code}, Body: #{response.body}"
      raise SimplefinError.new("SimpleFin server error (#{response.code}). Please try again later.", :server_error)
    else
      Rails.logger.error "SimpleFin API: Unexpected response - Code: #{response.code}, Body: #{response.body}"
      raise SimplefinError.new("Failed to fetch accounts: #{response.code} #{response.message} - #{response.body}", :fetch_failed)
    end
  end

  def get_info(base_url)
    # Use self.class.get to inherit class-level SSL and timeout defaults
    response = self.class.get("#{base_url}/info")

    case response.code
    when 200
      response.body.strip.split("\n")
    else
      raise SimplefinError.new("Failed to get server info: #{response.code} #{response.message}", :info_failed)
    end
  end

  # Native ingestion retains JSON numbers as decimals and never includes an
  # access URL, response body or transport exception text in errors or logs.
  # The adapter supplies bounded windows; an unfiltered call is account discovery.
  def get_accounts_snapshot(access_url, start_date: nil, end_date: nil, pending:)
    raise ArgumentError, "pending must be explicitly resolved" unless [ true, false ].include?(pending)
    uri = URI.parse(access_url)
    raise ArgumentError, "Invalid SimpleFIN access URL" unless uri.is_a?(URI::HTTP) && uri.host.present? && uri.query.nil? && uri.fragment.nil?
    if start_date || end_date
      start_time = start_date&.to_time
      end_time = end_date&.to_time
      unless start_time && end_time && start_time < end_time && end_time - start_time <= 60 * 24 * 60 * 60
        raise ArgumentError, "SimpleFIN windows must be positive and at most sixty days"
      end
    end
    query = {}
    query["start-date"] = start_date.to_time.to_i.to_s if start_date
    query["end-date"] = end_date.to_time.to_i.to_s if end_date
    query["pending"] = "1" if pending
    url = "#{access_url.delete_suffix('/')}/accounts"
    url += "?#{URI.encode_www_form(query)}" if query.any?
    response = with_retries("GET /accounts", redact_errors: true) { self.class.get(url) }
    return JSON.parse(response.body, symbolize_names: true, decimal_class: BigDecimal) if response.code == 200

    type = { 400 => :bad_request, 402 => :payment_required, 403 => :access_forbidden, 429 => :rate_limited }.fetch(response.code, :fetch_failed)
    raise SimplefinError.new("SimpleFIN request failed (HTTP #{response.code})", type), cause: nil
  rescue JSON::ParserError, URI::InvalidURIError, TypeError
    raise SimplefinError.new("Invalid SimpleFIN response or configuration", :invalid_response), cause: nil
  end

  class SimplefinError < StandardError
    attr_reader :error_type

    def initialize(message, error_type = :unknown)
      super(message)
      @error_type = error_type
    end
  end

  private

    # Execute a block with retry logic and exponential backoff for transient network errors.
    # This helps handle temporary network issues that cause autosync failures while
    # manual sync (with user retry) succeeds.
    def with_retries(operation_name, max_retries: MAX_RETRIES, backoff: true, redact_errors: false)
      retries = 0

      begin
        yield
      rescue *RETRYABLE_ERRORS => e
        retries += 1

        if retries <= max_retries
          delay = calculate_retry_delay(retries)
          Rails.logger.warn(
            "SimpleFin API: #{operation_name} failed (attempt #{retries}/#{max_retries}): " \
            "#{e.class}: #{redact_errors ? 'transport failure' : e.message}. Retrying in #{delay}s..."
          )
          sleep(delay) if backoff && delay.to_f.positive?
          retry
        else
          Rails.logger.error(
            "SimpleFin API: #{operation_name} failed after #{max_retries} retries: " \
            "#{e.class}: #{redact_errors ? 'transport failure' : e.message}"
          )
          message = redact_errors ? "SimpleFIN network request failed" : "Network error after #{max_retries} retries: #{e.message}"
          raise SimplefinError.new(message, :network_error), cause: redact_errors ? nil : e
        end
      rescue SimplefinError => e
        # Preserve original error type and message.
        raise
      rescue => e
        # Non-retryable errors are logged and re-raised immediately
        Rails.logger.error "SimpleFin API: #{operation_name} failed with non-retryable error: #{e.class}: #{redact_errors ? 'transport failure' : e.message}"
        message = redact_errors ? "SimpleFIN network request failed" : "Exception during #{operation_name}: #{e.message}"
        raise SimplefinError.new(message, :request_failed), cause: redact_errors ? nil : e
      end
    end

    # Calculate delay with exponential backoff and jitter
    def calculate_retry_delay(retry_count)
      # Exponential backoff: 2^retry * initial_delay
      base_delay = INITIAL_RETRY_DELAY * (2 ** (retry_count - 1))
      # Add jitter (0-25% of base delay) to prevent thundering herd
      jitter = base_delay * rand * 0.25
      # Cap at max delay
      [ base_delay + jitter, MAX_RETRY_DELAY ].min
    end
end
