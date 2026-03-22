class Provider::Simplefin
  # Pending: some institutions do not return pending transactions even with `pending=1`.
  # This is provider variability (not a bug). For troubleshooting, you can set
  # `SIMPLEFIN_INCLUDE_PENDING=1` and/or `SIMPLEFIN_DEBUG_RAW=1` (both default-off).
  # These are centralized in `Rails.configuration.x.simplefin.*` via
  # `config/initializers/simplefin.rb`.
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

    # Use retry logic for transient network failures during token claim
    # Claim should be fast; keep request-path latency bounded.
    # Use self.class.post to inherit class-level SSL and timeout defaults
    response = with_retries("POST /claim", max_retries: 1, sleep: false) do
      self.class.post(claim_url, timeout: 15)
    end

    case response.code
    when 200
      # The response body contains the access URL with embedded credentials
      response.body.strip
    when 403
      raise SimplefinError.new("Setup token may be compromised, expired, or already used", :token_compromised)
    else
      raise SimplefinError.new("Failed to claim access URL: #{response.code} #{response.message}", :claim_failed)
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

    query_params["pending"] = pending ? "1" : "0" unless pending.nil?

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
    def with_retries(operation_name, max_retries: MAX_RETRIES, sleep: true)
      retries = 0

      begin
        yield
      rescue *RETRYABLE_ERRORS => e
        retries += 1

        if retries <= max_retries
          delay = calculate_retry_delay(retries)
          Rails.logger.warn(
            "SimpleFin API: #{operation_name} failed (attempt #{retries}/#{max_retries}): " \
            "#{e.class}: #{e.message}. Retrying in #{delay}s..."
          )
          Kernel.sleep(delay) if sleep && delay.to_f.positive?
          retry
        else
          Rails.logger.error(
            "SimpleFin API: #{operation_name} failed after #{max_retries} retries: " \
            "#{e.class}: #{e.message}"
          )
          raise SimplefinError.new(
            "Network error after #{max_retries} retries: #{e.message}",
            :network_error
          )
        end
      rescue SimplefinError => e
        # Preserve original error type and message.
        raise
      rescue => e
        # Non-retryable errors are logged and re-raised immediately
        Rails.logger.error "SimpleFin API: #{operation_name} failed with non-retryable error: #{e.class}: #{e.message}"
        raise SimplefinError.new("Exception during #{operation_name}: #{e.message}", :request_failed)
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
