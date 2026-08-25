# frozen_string_literal: true

require "digest"

class AiHealth
  # Performs bounded, non-destructive checks against the exact services used
  # by Sure. Results are cached briefly because this runs in an admin request,
  # and a failed check is recorded once per cache fill in both operator-facing
  # debug logs and the application log.
  class Probe
    CACHE_NAMESPACE = "ai_health/probes/v1"
    DEFAULT_CACHE_TTL = 60.seconds
    DEFAULT_TIMEOUT = 5
    EMBEDDING_TEST_INPUT = "Sure AI health check"

    Result = Data.define(:status, :checked_at, :failure_code, :http_status) do
      def passing?
        status == :passing
      end

      def failing?
        status == :failing
      end
    end

    class Failure < StandardError
      attr_reader :failure_code

      def initialize(failure_code)
        @failure_code = failure_code
        super(failure_code.to_s)
      end
    end

    def self.not_checked
      Result.new(status: :not_checked, checked_at: nil, failure_code: nil, http_status: nil)
    end

    def self.not_configured
      Result.new(status: :not_configured, checked_at: nil, failure_code: nil, http_status: nil)
    end

    def initialize(force: false, cache: Rails.cache)
      @force = force
      @cache = cache
    end

    def llm(provider:, endpoint:, access_token:, model:)
      run(
        component: "llm",
        provider_key: provider,
        endpoint: endpoint,
        model: model,
        credential: access_token
      ) do
        model_available = case provider
        when :openai
          response = openai_client(access_token:, endpoint:).models.list
          openai_model_ids(response).include?(model)
        when :anthropic
          model_info = anthropic_client(access_token:, endpoint:).models.retrieve(model)
          model_info.respond_to?(:id) && model_info.id.present?
        else
          raise Failure, :unsupported_provider
        end

        raise Failure, :model_not_available unless model_available
      end
    end

    def openai_vector_store(endpoint:, access_token:)
      run(
        component: "vector_store",
        provider_key: :openai,
        endpoint: endpoint,
        credential: access_token
      ) do
        response = openai_client(access_token:, endpoint:).vector_stores.list(parameters: { limit: 1 })
        raise Failure, :invalid_response unless response.is_a?(Hash) && response["data"].is_a?(Array)
      end
    end

    def pgvector(connection: ActiveRecord::Base.connection)
      run(component: "vector_store", provider_key: :pgvector) do
        raise Failure, :extension_not_enabled unless connection.extension_enabled?("vector")
        raise Failure, :table_not_found unless connection.table_exists?(VectorStore::Pgvector::TABLE_NAME)

        table = connection.quote_table_name(VectorStore::Pgvector::TABLE_NAME)
        connection.select_value("SELECT 1 FROM #{table} LIMIT 1")
      end
    end

    def embedding(endpoint:, access_token:, model:, dimensions:)
      run(
        component: "embedding",
        provider_key: :openai_compatible,
        endpoint: endpoint,
        model: model,
        credential: access_token,
        dimensions: dimensions
      ) do
        response = embedding_client(endpoint:, access_token:).post("embeddings") do |request|
          request.body = { model: model, input: EMBEDDING_TEST_INPUT }
        end

        vector = response.body.dig("data", 0, "embedding") if response.body.is_a?(Hash)
        raise Failure, :invalid_response unless vector.is_a?(Array)
        raise Failure, :dimensions_mismatch unless vector.length == dimensions
      end
    end

    private
      attr_reader :cache, :force

      def run(component:, provider_key:, endpoint: nil, model: nil, credential: nil, dimensions: nil)
        key = cache_key(component:, provider_key:, endpoint:, model:, credential:, dimensions:)
        cache.delete(key) if force

        result = nil
        cache.fetch(key, expires_in: cache_ttl) do
          result = perform(component:, provider_key:, endpoint:, model:) { yield }
        end
      rescue StandardError => error
        record_cache_failure(error)
        result || perform(component:, provider_key:, endpoint:, model:) { yield }
      end

      def perform(component:, provider_key:, endpoint:, model:)
        yield
        Result.new(status: :passing, checked_at: Time.current, failure_code: nil, http_status: nil)
      rescue StandardError => error
        result = Result.new(
          status: :failing,
          checked_at: Time.current,
          failure_code: failure_code(error),
          http_status: http_status(error)
        )
        record_failure(component:, provider_key:, endpoint:, model:, error:, result:)
        result
      end

      def openai_client(access_token:, endpoint:)
        options = { access_token: access_token, request_timeout: timeout }
        options[:uri_base] = endpoint if endpoint.present?
        ::OpenAI::Client.new(**options)
      end

      def anthropic_client(access_token:, endpoint:)
        options = { api_key: access_token, max_retries: 0, timeout: timeout }
        options[:base_url] = endpoint if endpoint.present?
        ::Anthropic::Client.new(**options)
      end

      def embedding_client(endpoint:, access_token:)
        Faraday.new(url: endpoint) do |faraday|
          faraday.request :json
          faraday.response :json
          faraday.response :raise_error
          faraday.headers["Authorization"] = "Bearer #{access_token}" if access_token.present?
          faraday.options.timeout = timeout
          faraday.options.open_timeout = [ timeout, 3 ].min
        end
      end

      def openai_model_ids(response)
        raise Failure, :invalid_response unless response.is_a?(Hash) && response["data"].is_a?(Array)

        response["data"].filter_map { |item| item["id"] || item[:id] }
      end

      def cache_key(component:, provider_key:, endpoint:, model:, credential:, dimensions:)
        fingerprint = Digest::SHA256.hexdigest(
          [ component, provider_key, endpoint, model, credential, dimensions ].join("\0")
        )
        "#{CACHE_NAMESPACE}/#{fingerprint}"
      end

      def cache_ttl
        seconds = ENV.fetch("AI_HEALTH_PROBE_CACHE_TTL", DEFAULT_CACHE_TTL.to_i).to_i
        seconds.positive? ? seconds.seconds : DEFAULT_CACHE_TTL
      end

      def timeout
        seconds = ENV.fetch("AI_HEALTH_PROBE_TIMEOUT", DEFAULT_TIMEOUT).to_i
        seconds.positive? ? seconds : DEFAULT_TIMEOUT
      end

      def failure_code(error)
        return error.failure_code if error.respond_to?(:failure_code)

        error.is_a?(Faraday::TimeoutError) ? :timeout : :request_failed
      end

      def http_status(error)
        response = error.respond_to?(:response) ? error.response : nil
        return response[:status] || response["status"] if response.is_a?(Hash)

        error.status if error.respond_to?(:status)
      end

      def record_failure(component:, provider_key:, endpoint:, model:, error:, result:)
        message = "AI health #{component.tr('_', ' ')} liveness probe failed"
        metadata = {
          component: component,
          endpoint: AiHealth.redact_endpoint(endpoint),
          model: model,
          failure_code: result.failure_code,
          exception_class: error.class.name,
          http_status: result.http_status
        }.compact

        Rails.logger.error("#{message}: #{metadata.to_json}")
        DebugLogEntry.capture(
          category: "ai_health",
          level: "error",
          message: message,
          source: self.class.name,
          provider_key: provider_key.to_s,
          metadata: metadata
        )
      end

      def record_cache_failure(error)
        message = "AI health probe cache failed"
        Rails.logger.warn("#{message}: #{error.class.name}")
        DebugLogEntry.capture(
          category: "ai_health",
          level: "warn",
          message: message,
          source: self.class.name,
          metadata: { exception_class: error.class.name }
        )
      end
  end
end
