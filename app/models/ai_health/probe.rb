# frozen_string_literal: true

require "digest"
require "timeout"

class AiHealth
  # Performs bounded, non-destructive checks against the exact services used
  # by Sure. Results are cached briefly because this runs in an admin request,
  # and a failed check is recorded once per cache fill in both operator-facing
  # debug logs and the application log.
  #
  # The checks go through the AI transports (Ai::Transport#probe) and the
  # clients Ai::Transport::Http builds, so a probe exercises the same client
  # settings, headers, proxy and error mapping as production calls, and can't
  # drift from them. The probe builds no client of its own.
  class Probe
    CACHE_NAMESPACE = "ai_health/probes/v2"
    DEFAULT_CACHE_TTL = 60.seconds
    DEFAULT_TIMEOUT = 5
    # 4xx statuses that mean "not now" or "not you" rather than "not this
    # request": a retry, a payment, or a fixed credential clears them, so they
    # are never worth re-asking without the tools.
    TRANSIENT_HTTP_STATUSES = [ 401, 402, 403, 408, 429 ].freeze
    PDF_TEST_INSTITUTION = "SUREHEALTHCHECKBANK"
    PDF_TEST_LINES = [
      "Bank Statement",
      "Institution: #{PDF_TEST_INSTITUTION}",
      "Account holder: Health Check",
      "Statement period: 2026-01-01 to 2026-01-31",
      "Opening balance: USD 100.00",
      "Closing balance: USD 125.00",
      "Transactions: 2",
      "Synthetic data only. No customer data."
    ].freeze
    PDF_MAX_RESPONSE_TOKENS = 512

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

    # Seconds each probe request is allowed to run. Single source of truth:
    # both the probes (instance methods below) and AiHealth's System Health
    # reporting resolve the effective timeout through here so the two can
    # never drift. Precedence: AI_HEALTH_PROBE_TIMEOUT > the Self-Hosting
    # setting > DEFAULT_TIMEOUT, with non-positive values treated as unset.
    def self.timeout
      seconds = ENV["AI_HEALTH_PROBE_TIMEOUT"].to_s.strip.to_i
      seconds = Setting.ai_health_probe_timeout.to_i unless seconds.positive?
      seconds.positive? ? seconds : DEFAULT_TIMEOUT
    end

    def initialize(force: false, cache: Rails.cache)
      @force = force
      @cache = cache
    end

    # Whether the model is up, by the endpoint's probe check: :models lists the
    # server's models and makes no chat call (the default for every endpoint);
    # :chat sends one tiny request. Which one is the endpoint's
    # `probe_check`, :models unless the endpoint asks for a chat request.
    def llm(provider:, endpoint:, access_token:, model:)
      probe_endpoint = config_endpoint(provider:, base_url: endpoint, api_key: access_token)

      run(
        component: "llm",
        provider_key: provider,
        endpoint: endpoint,
        model: model,
        credential: access_token,
        verification: probe_endpoint.probe_check
      ) do
        raise_unsupported_provider!(provider)
        transport_for(probe_endpoint).probe(config_model(probe_endpoint, model), probe_endpoint.probe_check, timeout:)
      end
    end

    # The assistant reads financial data exclusively through function calls, so
    # a model that rejects or ignores the `tools` parameter cannot power chat
    # even when the plain check above passes. Providers report this
    # inconsistently — OpenRouter answers a bare 404 — so ask the configured
    # model for one trivial tool call and report what came back. The caller
    # picks the OpenAI API, because `Provider::Openai#supports_responses_endpoint?`
    # can be overridden: probing the route chat does not take proves nothing.
    def function_calling(provider:, endpoint:, access_token:, model:, use_responses_endpoint: false)
      run(
        component: "function_calling",
        provider_key: provider,
        endpoint: endpoint,
        model: model,
        credential: access_token,
        verification: use_responses_endpoint ? :responses_tool_call : :chat_tool_call
      ) do
        raise_unsupported_provider!(provider)
        probe_endpoint = config_endpoint(provider:, base_url: endpoint, api_key: access_token, responses_api: use_responses_endpoint)
        transport = transport_for(probe_endpoint)
        probe_model = config_model(probe_endpoint, model)

        tool_called = confirming_tools_refusal(
          tools: -> { transport.probe(probe_model, :tools, timeout:) },
          control: -> { transport.probe(probe_model, :chat, timeout:) }
        )

        raise Failure, :no_tool_call unless tool_called
      end
    end

    def pdf_text_extraction(provider:, endpoint:, access_token:, model:, openai_compatible: false)
      pdf_processing(
        provider: provider,
        endpoint: endpoint,
        access_token: access_token,
        model: model,
        openai_compatible: openai_compatible,
        component: "pdf_text_extraction",
        verification: :synthetic_pdf_text,
        processing_mode: :text
      )
    end

    def pdf_vision_processing(provider:, endpoint:, access_token:, model:, openai_compatible: false)
      pdf_processing(
        provider: provider,
        endpoint: endpoint,
        access_token: access_token,
        model: model,
        openai_compatible: openai_compatible,
        component: "pdf_vision_processing",
        verification: :synthetic_pdf_vision,
        processing_mode: :vision
      )
    end

    def openai_vector_store(endpoint:, access_token:)
      run(
        component: "vector_store",
        provider_key: :openai,
        endpoint: endpoint,
        credential: access_token
      ) do
        client = Ai::Transport::Http.openai_client(config_endpoint(provider: :openai, base_url: endpoint, api_key: access_token), timeout:)
        response = client.vector_stores.list(parameters: { limit: 1 })
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
        probe_endpoint = config_endpoint(provider: :openai_compatible, base_url: endpoint, api_key: access_token, extra_headers: {})
        returned = transport_for(probe_endpoint).probe(config_model(probe_endpoint, model), :embedding, timeout:)
        raise Failure, :dimensions_mismatch unless returned == dimensions
      end
    end

    private
      attr_reader :cache, :force

      def pdf_processing(provider:, endpoint:, access_token:, model:, openai_compatible:, component:, verification:,
                         processing_mode:)
        run(
          component: component,
          provider_key: provider,
          endpoint: endpoint,
          model: model,
          credential: access_token,
          verification: verification
        ) do
          result = Timeout.timeout(timeout) do
            case provider
            when :openai
              Provider::Openai::PdfProcessor.new(
                Ai::Transport::Http.openai_client(config_endpoint(provider:, base_url: endpoint, api_key: access_token), timeout:),
                model: model,
                pdf_content: synthetic_pdf,
                custom_provider: openai_compatible,
                max_response_tokens: PDF_MAX_RESPONSE_TOKENS,
                processing_mode: processing_mode
              ).process
            when :anthropic
              raise Failure, :unsupported_provider unless processing_mode == :vision

              Provider::Anthropic::PdfProcessor.new(
                Ai::Transport::Http.anthropic_client(config_endpoint(provider:, base_url: endpoint, api_key: access_token), timeout:),
                model: model,
                pdf_content: synthetic_pdf
              ).process
            else
              raise Failure, :unsupported_provider
            end
          end

          raise Failure, :invalid_response unless valid_pdf_result?(result)
        end
      end

      def run(component:, provider_key:, endpoint: nil, model: nil, credential: nil, dimensions: nil, verification: nil)
        key = cache_key(component:, provider_key:, endpoint:, model:, credential:, dimensions:, verification:)
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

      # The endpoint value the transports take, built from what AiHealth resolved.
      # OpenAI-compatible LLM endpoints send the static OPENAI_EXTRA_HEADERS, as
      # Provider::Openai does; the embedding endpoint sends none, as
      # VectorStore::Embeddable doesn't.
      def config_endpoint(provider:, base_url:, api_key:, responses_api: false, extra_headers: nil)
        protocol = provider.to_sym == :anthropic ? :anthropic : :compatible
        extra_headers ||= protocol == :compatible ? Provider::Openai.extra_headers : {}

        Ai::Config::Endpoint.new(
          name: provider.to_s, protocol:, base_url:, api_key:, extra_headers:,
          timeout_seconds: timeout, max_retries: 0, responses_api:
        )
      end

      def config_model(endpoint, name) = Ai::Config::Model.new(endpoint:, name:)

      def transport_for(endpoint) = Ai::Transport.for(endpoint)

      def raise_unsupported_provider!(provider)
        raise Failure, :unsupported_provider unless provider.to_sym.in?(%i[openai anthropic])
      end

      # A client error can mean "your tools payload" or "your request, tools or
      # not" — an invalid schema, a route the endpoint does not serve, a model
      # it will not run. Asking again without the tools is the only
      # provider-agnostic way to tell those apart: if the same request lands
      # once the tools come off, the tools are what was turned down. Reading
      # the error text for the word "tool" instead would only ever fit the
      # provider whose wording it was written against.
      def confirming_tools_refusal(tools:, control:)
        tools.call
      rescue StandardError => error
        raise error unless client_error?(error)

        begin
          control.call
        rescue StandardError
          raise error
        end

        raise Failure, :tools_refused
      end

      def client_error?(error)
        status = http_status(error).to_i

        status.between?(400, 499) && !status.in?(TRANSIENT_HTTP_STATUSES)
      end

      def valid_pdf_result?(result)
        result.is_a?(Provider::LlmConcept::PdfProcessingResult) &&
          result.document_type == "bank_statement" &&
          result.extracted_data.is_a?(Hash) &&
          result.extracted_data["institution_name"] == PDF_TEST_INSTITUTION
      end

      def synthetic_pdf
        return @synthetic_pdf if defined?(@synthetic_pdf)

        text = PDF_TEST_LINES.map { |line| "(#{line}) Tj T*" }.join("\n")
        content = "BT /F1 14 Tf 24 190 Td 22 TL\n#{text}\nET\n".b
        objects = [
          "<< /Type /Catalog /Pages 2 0 R >>",
          "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
          "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 480 216] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
          "<< /Length #{content.bytesize} >>\nstream\n#{content}endstream",
          "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ]

        pdf = "%PDF-1.4\n".b
        offsets = [ 0 ]
        objects.each_with_index do |object, index|
          offsets << pdf.bytesize
          pdf << "#{index + 1} 0 obj\n#{object}\nendobj\n".b
        end

        xref_offset = pdf.bytesize
        pdf << "xref\n0 #{objects.size + 1}\n".b
        pdf << "0000000000 65535 f \n".b
        offsets.drop(1).each { |offset| pdf << format("%010d 00000 n \n", offset).b }
        pdf << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{xref_offset}\n%%EOF\n".b
        @synthetic_pdf = pdf.freeze
      end

      def cache_key(component:, provider_key:, endpoint:, model:, credential:, dimensions:, verification:)
        fingerprint = Digest::SHA256.hexdigest(
          [ component, provider_key, endpoint, model, credential, dimensions, verification ].join("\0")
        )
        "#{CACHE_NAMESPACE}/#{fingerprint}"
      end

      def cache_ttl
        seconds = ENV.fetch("AI_HEALTH_PROBE_CACHE_TTL", DEFAULT_CACHE_TTL.to_i).to_i
        seconds.positive? ? seconds.seconds : DEFAULT_CACHE_TTL
      end

      def timeout
        self.class.timeout
      end

      # Map a probe error to a machine-readable code for the admin AI status
      # page. Prefers an explicit `failure_code` the error carries (e.g. a
      # provider raising for a specific reason like a missing renderer binary),
      # then classifies Faraday/Timeout errors as :timeout, and falls back to
      # :request_failed for everything else.
      def failure_code(error)
        code = error.failure_code if error.respond_to?(:failure_code)
        return code if code

        case error
        when Ai::Error::ModelMissing then :model_not_available
        when Ai::Error::NoCredit then :no_credit
        when Ai::Error::Unauthorized then :unauthorized
        when Ai::Error::Unreachable then :unreachable
        when Ai::Error::InvalidOutput then :invalid_response
        when Ai::Error::Timeout, Faraday::TimeoutError, Timeout::Error then :timeout
        else :request_failed
        end
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
