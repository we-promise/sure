class Provider::Up
  include HTTParty
  extend SslConfigurable

  DEFAULT_BASE_URL = "https://api.up.com.au/api/v1".freeze
  DEFAULT_PAGE_SIZE = 100
  # Host that authenticated requests (bearer token) may be sent to. Absolute URLs
  # taken from API responses (links.next) are validated against this.
  ALLOWED_HOST = URI.parse(DEFAULT_BASE_URL).host.freeze

  headers "User-Agent" => "Sure Finance Up Client"
  default_options.merge!({ timeout: 120 }.merge(httparty_ssl_options))

  attr_reader :access_token

  # Build a client with the family's Up personal access token. Raises if blank.
  def initialize(access_token)
    @access_token = access_token.to_s.strip

    raise UpError.new("Up access token is required", :configuration_error) if @access_token.blank?
  end

  # GET /util/ping - validates the personal access token.
  # Returns the parsed payload (contains meta.id / meta.statusEmoji) or raises UpError.
  def ping
    get("util/ping")
  end

  # GET /accounts - returns an array of flattened account hashes.
  # Each hash: { id:, displayName:, accountType:, ownershipType:, balance: {...}, createdAt: }
  def get_accounts
    fetch_all_resources("accounts").map { |resource| flatten_account(resource) }
  end

  # GET /accounts/{id}/transactions - returns an array of flattened transaction hashes.
  # Both HELD (pending) and SETTLED (posted) transactions are returned; callers derive
  # pending status from the :status field.
  def get_account_transactions(account_id:, since: nil, until_date: nil, page_size: DEFAULT_PAGE_SIZE)
    query = { "page[size]" => page_size }
    query["filter[since]"] = format_api_time(since) if since.present?
    query["filter[until]"] = format_api_time(until_date) if until_date.present?

    path = "accounts/#{ERB::Util.url_encode(account_id.to_s)}/transactions"
    fetch_all_resources(path, query: query).map { |resource| flatten_transaction(resource) }
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

    # Follows JSON:API cursor pagination via links.next (absolute URLs) until exhausted,
    # concatenating each page's `data` array.
    def fetch_all_resources(path, query: {})
      results = []
      payload = get(path, query: query.presence)
      seen_urls = Set.new

      loop do
        results.concat(Array(payload[:data]))
        next_url = payload.dig(:links, :next)
        break if next_url.blank?
        # Guard against an API that returns the same cursor repeatedly.
        break unless seen_urls.add?(next_url)

        payload = get(next_url)
      end

      results
    end

    # Flattens a JSON:API account resource into a single hash with id + attributes.
    def flatten_account(resource)
      data = resource.with_indifferent_access
      attributes = data[:attributes].is_a?(Hash) ? data[:attributes] : {}

      attributes.merge(
        id: data[:id],
        type: data[:type]
      ).with_indifferent_access
    end

    # Flattens a JSON:API transaction resource, lifting attributes to the top level and
    # extracting the related account/category ids from relationships.
    def flatten_transaction(resource)
      data = resource.with_indifferent_access
      attributes = data[:attributes].is_a?(Hash) ? data[:attributes] : {}

      attributes.merge(
        id: data[:id],
        account_id: data.dig(:relationships, :account, :data, :id),
        category_id: data.dig(:relationships, :category, :data, :id)
      ).with_indifferent_access
    end

    def format_api_time(value)
      return value if value.is_a?(String)
      # A bare Date has no time/zone, so interpret it as UTC midnight rather than
      # the server's local zone (which would shift `filter[since]` by the offset).
      return value.to_time(:utc).iso8601 if value.instance_of?(Date)

      value.to_time.utc.iso8601
    end

    # Issues a GET request. `path_or_url` may be a relative path (prefixed with the base URL)
    # or an absolute URL (used when following pagination links).
    def get(path_or_url, query: nil)
      with_retries("GET #{path_or_url}") do
        url = resolve_url(path_or_url)
        response = self.class.get(url, headers: auth_headers, query: query)
        handle_response(response)
      end
    end

    # Resolves a relative path against the base URL, or validates an absolute URL
    # so the bearer token is only ever sent to Up's HTTPS host.
    def resolve_url(path_or_url)
      value = path_or_url.to_s
      return "#{DEFAULT_BASE_URL}/#{value}" unless value.start_with?("http")

      uri = URI.parse(value)
      unless uri.scheme == "https" && uri.host == ALLOWED_HOST
        raise UpError.new("Refusing to send credentials to untrusted host: #{uri.host.inspect}", :invalid_url)
      end

      value
    rescue URI::InvalidURIError
      raise UpError.new("Invalid Up API URL", :invalid_url)
    end

    # Bearer-auth headers sent with every request.
    def auth_headers
      {
        "Authorization" => "Bearer #{access_token}",
        "Accept" => "application/json"
      }
    end

    # Run the block, retrying transient network errors with exponential backoff.
    def with_retries(operation_name, max_retries: MAX_RETRIES)
      retries = 0

      begin
        yield
      rescue *RETRYABLE_ERRORS => e
        retries += 1
        if retries <= max_retries
          delay = calculate_retry_delay(retries)
          Rails.logger.warn(
            "Up API: #{operation_name} failed (attempt #{retries}/#{max_retries}): " \
            "#{e.class}: #{e.message}. Retrying in #{delay}s..."
          )
          Kernel.sleep(delay)
          retry
        end

        Rails.logger.error("Up API: #{operation_name} failed after #{max_retries} retries: #{e.class}: #{e.message}")
        raise UpError.new("Network error after #{max_retries} retries: #{e.message}", :network_error)
      end
    end

    # Exponential backoff delay (with jitter), capped at 30 seconds.
    def calculate_retry_delay(retry_count)
      base_delay = INITIAL_RETRY_DELAY * (2 ** (retry_count - 1))
      jitter = base_delay * rand * 0.25
      [ base_delay + jitter, 30 ].min
    end

    # Map an HTTP response to parsed data or a typed UpError by status code.
    def handle_response(response)
      case response.code
      when 200, 201
        parse_response_body(response)
      when 204
        {}
      when 400
        raise UpError.new("Bad request to Up API (status=#{response.code})", :bad_request)
      when 401
        raise UpError.new("Invalid Up access token", :unauthorized)
      when 403
        raise UpError.new("Up access forbidden - check token permissions", :access_forbidden)
      when 404
        raise UpError.new("Up resource not found", :not_found)
      when 429
        raise UpError.new("Up rate limit exceeded. Please try again later.", :rate_limited)
      when 500..599
        raise UpError.new("Up server error (#{response.code}). Please try again later.", :server_error)
      else
        Rails.logger.error "Up API: Unexpected response status=#{response.code}"
        raise UpError.new("Failed to fetch Up data", :fetch_failed)
      end
    end

    # Parse a JSON response body into a symbol-keyed hash, raising on bad JSON.
    def parse_response_body(response)
      return {} if response.body.blank?

      JSON.parse(response.body, symbolize_names: true)
    rescue JSON::ParserError => e
      Rails.logger.error "Up API: Failed to parse response: #{e.class}"
      raise UpError.new("Failed to parse Up API response", :parse_error)
    end

    # Error raised for Up API failures, tagged with a symbolic +error_type+.
    class UpError < StandardError
      attr_reader :error_type

      # Build the error with a +message+ and a categorizing +error_type+.
      def initialize(message, error_type = :unknown)
        super(message)
        @error_type = error_type
      end
    end
end
