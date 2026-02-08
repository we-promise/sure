class Eval::Langfuse::Client
  extend SslConfigurable

  BASE_URLS = {
    us: "https://us.cloud.langfuse.com/api/public",
    eu: "https://cloud.langfuse.com/api/public"
  }.freeze

  # OpenSSL 3.x version threshold for CRL workaround
  # See: https://github.com/ruby/openssl/issues/619
  OPENSSL_3_VERSION = 0x30000000

  # CRL-related OpenSSL error codes that can be safely bypassed
  # These errors occur when CRL (Certificate Revocation List) is unavailable
  def self.crl_errors
    @crl_errors ||= begin
      errors = [
        OpenSSL::X509::V_ERR_UNABLE_TO_GET_CRL,
        OpenSSL::X509::V_ERR_CRL_HAS_EXPIRED,
        OpenSSL::X509::V_ERR_CRL_NOT_YET_VALID
      ]
      # V_ERR_UNABLE_TO_GET_CRL_ISSUER may not exist in all OpenSSL versions
      errors << OpenSSL::X509::V_ERR_UNABLE_TO_GET_CRL_ISSUER if defined?(OpenSSL::X509::V_ERR_UNABLE_TO_GET_CRL_ISSUER)
      errors.freeze
    end
  end

  class Error < StandardError; end
  class ConfigurationError < Error; end
  class ApiError < Error
    attr_reader :status, :body

    def initialize(message, status: nil, body: nil)
      super(message)
      @status = status
      @body = body
    end
  end

  def initialize(public_key: nil, secret_key: nil, region: nil, host: nil)
    @public_key = public_key || ENV["LANGFUSE_PUBLIC_KEY"]
    @secret_key = secret_key || ENV["LANGFUSE_SECRET_KEY"]
    @base_url = determine_base_url(region, host)

    validate_configuration!
  end

  # Dataset operations
  def create_dataset(name:, description: nil, metadata: {})
    post("/v2/datasets", {
      name: name,
      description: description,
      metadata: metadata
    }.compact)
  end

  def get_dataset(name:)
    get("/v2/datasets/#{encode(name)}")
  end

  def list_datasets(page: 1, limit: 50)
    get("/v2/datasets", page: page, limit: limit)
  end

  # Dataset item operations
  def create_dataset_item(dataset_name:, input:, expected_output: nil, metadata: {}, id: nil)
    post("/dataset-items", {
      datasetName: dataset_name,
      id: id,
      input: input,
      expectedOutput: expected_output,
      metadata: metadata
    }.compact)
  end

  def get_dataset_items(dataset_name:, page: 1, limit: 50)
    get("/dataset-items", datasetName: dataset_name, page: page, limit: limit)
  end

  # Dataset run operations (for experiments)
  def create_dataset_run_item(run_name:, dataset_item_id:, trace_id: nil, observation_id: nil, metadata: {})
    post("/dataset-run-items", {
      runName: run_name,
      datasetItemId: dataset_item_id,
      traceId: trace_id,
      observationId: observation_id,
      metadata: metadata
    }.compact)
  end

  # Trace operations
  def create_trace(name:, input: nil, output: nil, metadata: {}, session_id: nil, user_id: nil)
    # Generate trace ID upfront so we can return it
    trace_id = SecureRandom.uuid

    post("/ingestion", {
      batch: [
        {
          id: SecureRandom.uuid,
          type: "trace-create",
          timestamp: Time.current.iso8601,
          body: {
            id: trace_id,
            name: name,
            input: input,
            output: output,
            metadata: metadata,
            sessionId: session_id,
            userId: user_id
          }.compact
        }
      ]
    })

    # Return the trace ID we generated
    trace_id
  end

  # Score operations
  def create_score(trace_id:, name:, value:, comment: nil, data_type: "NUMERIC")
    post("/ingestion", {
      batch: [
        {
          id: SecureRandom.uuid,
          type: "score-create",
          timestamp: Time.current.iso8601,
          body: {
            id: SecureRandom.uuid,
            traceId: trace_id,
            name: name,
            value: value,
            comment: comment,
            dataType: data_type
          }.compact
        }
      ]
    })
  end

  def configured?
    @public_key.present? && @secret_key.present?
  end

  private

    def determine_base_url(region, host)
      # Priority: explicit host > LANGFUSE_HOST env > region > LANGFUSE_REGION env > default (eu)
      if host.present?
        host.chomp("/") + "/api/public"
      elsif ENV["LANGFUSE_HOST"].present?
        ENV["LANGFUSE_HOST"].chomp("/") + "/api/public"
      elsif region.present?
        BASE_URLS[region.to_sym] || BASE_URLS[:eu]
      elsif ENV["LANGFUSE_REGION"].present?
        BASE_URLS[ENV["LANGFUSE_REGION"].to_sym] || BASE_URLS[:eu]
      else
        # Default to EU as it's more common
        BASE_URLS[:eu]
      end
    end

    def validate_configuration!
      return if configured?

      raise ConfigurationError, <<~MSG
      Langfuse credentials not configured.
      Set LANGFUSE_PUBLIC_KEY and LANGFUSE_SECRET_KEY environment variables,
      or pass public_key and secret_key to the client.
    MSG
    end

    def get(path, params = {})
      uri = build_uri(path, params)
      request = Net::HTTP::Get.new(uri)
      execute_request(uri, request)
    end

    def post(path, body)
      uri = build_uri(path)
      request = Net::HTTP::Post.new(uri)
      request.body = body.to_json
      request["Content-Type"] = "application/json"
      execute_request(uri, request)
    end

    def build_uri(path, params = {})
      uri = URI("#{@base_url}#{path}")
      uri.query = URI.encode_www_form(params) if params.any?
      uri
    end

    def execute_request(uri, request, retries: 3)
      request.basic_auth(@public_key, @secret_key)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 30
      http.open_timeout = 10

      # Apply SSL configuration from centralized config
      http.verify_mode = self.class.net_http_verify_mode
      http.ca_file = self.class.ssl_ca_file if self.class.ssl_ca_file.present?

      # Fix for OpenSSL 3.x CRL checking issues (only when verification is enabled)
      # See: https://github.com/ruby/openssl/issues/619
      # Only bypass CRL-specific errors, not all certificate verification
      if self.class.ssl_verify? && OpenSSL::OPENSSL_VERSION_NUMBER >= OPENSSL_3_VERSION
        crl_error_codes = self.class.crl_errors
        http.verify_callback = ->(preverify_ok, store_ctx) {
          # Bypass only CRL-specific errors (these fail when CRL is unavailable)
          # For all other errors, preserve the original verification result
          if crl_error_codes.include?(store_ctx.error)
            true
          else
            preverify_ok
          end
        }
      end

      response = http.request(request)

      case response.code.to_i
      when 200..299
        JSON.parse(response.body) rescue {}
      when 401
        raise ApiError.new("Unauthorized - check your Langfuse API keys", status: 401, body: response.body)
      when 404
        raise ApiError.new("Resource not found", status: 404, body: response.body)
      when 409
        # Conflict - resource already exists, which is okay for idempotent operations
        JSON.parse(response.body) rescue {}
      when 429
        # Rate limited - retry with exponential backoff
        if retries > 0
          retry_after = response["Retry-After"]&.to_i || (2 ** (3 - retries))
          Rails.logger.info("[Langfuse] Rate limited, waiting #{retry_after}s before retry...")
          sleep(retry_after)
          execute_request(uri, rebuild_request(request), retries: retries - 1)
        else
          raise ApiError.new("Rate limit exceeded after retries", status: 429, body: response.body)
        end
      else
        raise ApiError.new("API error: #{response.code} - #{response.body}", status: response.code.to_i, body: response.body)
      end
    end

    def rebuild_request(original_request)
      # Create a new request with the same properties (needed for retry since request body may be consumed)
      uri = URI(original_request.uri.to_s)
      new_request = original_request.class.new(uri)
      original_request.each_header { |key, value| new_request[key] = value }
      new_request.body = original_request.body
      new_request
    end

    def encode(value)
      ERB::Util.url_encode(value)
    end
end
