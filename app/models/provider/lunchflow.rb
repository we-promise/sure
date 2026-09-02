class Provider::Lunchflow
  include HTTParty
  extend SslConfigurable

  headers "User-Agent" => "Sure Finance Lunch Flow Client"
  default_options.merge!({ timeout: 120 }.merge(httparty_ssl_options))

  MAX_RETRIES = 2
  MAX_RATE_LIMIT_RETRIES = 1
  INITIAL_RETRY_DELAY = 2
  MAX_RETRY_DELAY = 60
  DEFAULT_RATE_LIMIT_DELAY = 60
  NETWORK_ERRORS = Provider::HttpTransport::TRANSPORT_ERRORS

  attr_reader :api_key, :base_url

  def initialize(api_key, base_url: "https://lunchflow.app/api/v1")
    @api_key = api_key
    @base_url = base_url
  end

  # Get all accounts
  # Returns: { accounts: [...], total: N }
  def get_accounts
    get("/accounts")
  end

  # Get transactions for a specific account
  # Returns: { transactions: [...], total: N }
  # Transaction structure: { id, accountId, amount, currency, date, merchant, description, isPending }
  def get_account_transactions(account_id, start_date: nil, end_date: nil, include_pending: false)
    query_params = {}

    if start_date
      query_params[:start_date] = start_date.to_date.to_s
    end

    if end_date
      query_params[:end_date] = end_date.to_date.to_s
    end

    if include_pending
      query_params[:include_pending] = true
    end

    path = "/accounts/#{ERB::Util.url_encode(account_id.to_s)}/transactions"
    path += "?#{URI.encode_www_form(query_params)}" unless query_params.empty?

    get(path)
  end

  # Get balance for a specific account
  # Returns: { balance: { amount: N, currency: "USD" } }
  def get_account_balance(account_id)
    path = "/accounts/#{ERB::Util.url_encode(account_id.to_s)}/balance"

    get(path)
  end

  # Get holdings for a specific account (investment accounts only)
  # Returns: { holdings: [...], totalValue: N, currency: "USD" }
  # Returns { holdings_not_supported: true } if API returns 501
  def get_account_holdings(account_id)
    path = "/accounts/#{ERB::Util.url_encode(account_id.to_s)}/holdings"

    get(path, holdings_not_supported: true)
  end

  private

    def get(path, holdings_not_supported: false)
      operation_name = "GET #{path}"

      with_retries(operation_name) do
        response = self.class.get(
          "#{base_url}#{path}",
          headers: auth_headers
        )

        if holdings_not_supported && response.code == 501
          { holdings_not_supported: true }
        else
          handle_response(response)
        end
      end
    end

    def auth_headers
      {
        "x-api-key" => api_key,
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }
    end

    def handle_response(response)
      case response.code
      when 200
        JSON.parse(response.body, symbolize_names: true)
      when 400
        raise LunchflowError.new("Bad request to Lunch Flow API: #{response.body}", :bad_request, status: response.code)
      when 401
        raise LunchflowError.new("Invalid API key", :unauthorized, status: response.code)
      when 403
        raise LunchflowError.new("Access forbidden - check your API key permissions", :access_forbidden, status: response.code)
      when 404
        raise LunchflowError.new("Resource not found", :not_found, status: response.code)
      when 429
        raise rate_limit_error(response)
      else
        raise rate_limit_error(response) if rate_limited_response?(response)

        error_type = response.code.in?(500..599) ? :server_error : :fetch_failed
        raise LunchflowError.new(
          "Failed to fetch data: #{response.code} #{response.message} - #{response.body}",
          error_type,
          status: response.code
        )
      end
    end

    def with_retries(operation_name, max_retries: MAX_RETRIES)
      retries = 0

      begin
        yield
      rescue => original_error
        error = normalize_request_error(original_error, operation_name)
        unless retryable_error?(error, original_error)
          capture_terminal_error(operation_name, error, original_error)
          raise error
        end

        retry_limit = error.error_type == :rate_limited ? MAX_RATE_LIMIT_RETRIES : max_retries
        if retries >= retry_limit
          capture_terminal_error(operation_name, error, original_error, retries:, retry_limit:)
          raise error
        end

        retries += 1
        delay = retry_delay(error, retries)
        DebugLogEntry.capture(
          category: "provider_sync",
          level: "warn",
          message: "Lunch Flow API request will be retried",
          source: self.class.name,
          provider_key: "lunchflow",
          metadata: {
            operation: operation_name,
            error_type: error.error_type,
            error_class: original_error.class.name,
            retry_attempt: retries,
            retry_limit: retry_limit,
            retry_delay: delay
          }
        )
        Rails.logger.warn(
          "Lunch Flow API: #{operation_name} failed (retry #{retries}/#{retry_limit}): " \
          "#{error.error_type}. Retrying in #{delay}s..."
        )
        sleep(delay) if delay.positive?
        retry
      end
    end

    def normalize_request_error(error, operation_name)
      return error if error.is_a?(LunchflowError)

      if NETWORK_ERRORS.any? { |error_class| error.is_a?(error_class) }
        return LunchflowError.new("#{operation_name} failed: #{error.message}", :request_failed)
      end

      LunchflowError.new("Exception during #{operation_name}: #{error.message}", :request_failed)
    end

    def capture_terminal_error(operation_name, error, original_error, retries: nil, retry_limit: nil)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "error",
        message: "Lunch Flow API request failed",
        source: self.class.name,
        provider_key: "lunchflow",
        metadata: {
          operation: operation_name,
          status: error.status,
          error_type: error.error_type,
          error_class: original_error.class.name,
          retry_attempts: retries,
          retry_limit: retry_limit
        }
      )
    end

    def retryable_error?(error, original_error)
      error.error_type.in?([ :rate_limited, :server_error ]) ||
        NETWORK_ERRORS.any? { |error_class| original_error.is_a?(error_class) }
    end

    def retry_delay(error, retry_count)
      return error.retry_after || DEFAULT_RATE_LIMIT_DELAY if error.error_type == :rate_limited

      base_delay = INITIAL_RETRY_DELAY * (2 ** (retry_count - 1))
      jitter = base_delay * rand * 0.25
      [ base_delay + jitter, MAX_RETRY_DELAY ].min
    end

    def rate_limited_response?(response)
      body = parsed_response_body(response)
      body["error"].to_s.match?(/rate.?limit/i) ||
        body["message"].to_s.match?(/(?:429|rate.?limit)/i) ||
        response.body.to_s.match?(/(?:GCRateLimited|429[^\n]*rate limit|rate limit exceeded)/i)
    end

    def rate_limit_error(response)
      body = parsed_response_body(response)
      message = body["message"].presence || "Rate limit exceeded. Please try again later."
      LunchflowError.new(
        message,
        :rate_limited,
        retry_after: retry_after_seconds(response, message),
        status: response.code
      )
    end

    def parsed_response_body(response)
      parsed_body = JSON.parse(response.body.to_s)
      parsed_body.is_a?(Hash) ? parsed_body : {}
    rescue JSON::ParserError
      {}
    end

    def retry_after_seconds(response, message)
      headers = response.headers if response.respond_to?(:headers)
      header = headers["retry-after"] if headers
      header_seconds = Float(header, exception: false)
      return [ header_seconds, MAX_RETRY_DELAY ].min if header_seconds&.positive?

      match = message.to_s.match(/try again in\s+(\d+(?:\.\d+)?)\s*seconds?/i)
      match ? [ match[1].to_f, MAX_RETRY_DELAY ].min : nil
    end

    class LunchflowError < StandardError
      attr_reader :error_type, :retry_after, :status

      def initialize(message, error_type = :unknown, retry_after: nil, status: nil)
        super(message)
        @error_type = error_type
        @retry_after = retry_after
        @status = status
      end
    end
end
