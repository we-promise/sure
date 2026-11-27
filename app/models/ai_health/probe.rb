# frozen_string_literal: true

require "digest"
require "timeout"

class AiHealth
  # Performs bounded, non-destructive checks against the exact services used
  # by Sure. Ai::ProbeJob runs them in a worker (`run: true`) and stores the
  # results in Ai::SharedState once every check is done; the admin page reads
  # them without calling a model. A failed check is recorded in both
  # operator-facing debug logs and the application log.
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
    PDF_MAX_RESPONSE_TOKENS = 512

    Result = Data.define(:status, :checked_at, :failure_code, :http_status) do
      def self.from_json(json)
        new(status: json["status"].to_sym, checked_at: json["checked_at"] && Time.zone.parse(json["checked_at"]),
            failure_code: json["failure_code"]&.to_sym, http_status: json["http_status"])
      end

      def passing?
        status == :passing
      end

      def failing?
        status == :failing
      end

      def not_checked?
        status == :not_checked
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

    # How long a result is kept (AI_HEALTH_PROBE_CACHE_TTL): the page shows "not checked" after.
    def self.cache_ttl
      seconds = ENV.fetch("AI_HEALTH_PROBE_CACHE_TTL", DEFAULT_CACHE_TTL.to_i).to_i
      seconds.positive? ? seconds.seconds : DEFAULT_CACHE_TTL
    end

    # run: probe now, and keep the results for #store!. Otherwise each check answers with its
    # stored result, or not_checked, and no AI request is made.
    def initialize(run: false)
      @run = run
      @results = {}
    end

    # Writes every result at once, so the first check's doesn't expire while the last one runs.
    def store!
      @results.each { |key, result| Ai::SharedState.write(key, result, expires_in: Probe.cache_ttl) }
    rescue StandardError => error
      record_store_failure(error)
    end

    # Whether the model is up, by the endpoint's `probe_check`
    # (Ai::Config::Endpoint::PROBE_CHECKS).
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
        probe_model = Ai::Config::Model.new(endpoint: probe_endpoint, name: model)
        Ai::Transport.for(probe_endpoint).probe(probe_model, probe_endpoint.probe_check, timeout:)
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
        transport = Ai::Transport.for(probe_endpoint)
        probe_model = Ai::Config::Model.new(endpoint: probe_endpoint, name: model)

        tool_called = confirming_tools_refusal(
          tools: -> { transport.probe(probe_model, :tools, timeout:) },
          control: -> { transport.probe(probe_model, :chat, timeout:) }
        )

        raise Failure, :no_tool_call unless tool_called
      end
    end

    def pdf_text_extraction(**connection)
      pdf_processing(**connection, component: "pdf_text_extraction", verification: :synthetic_pdf_text, processing_mode: :text)
    end

    def pdf_vision_processing(**connection)
      pdf_processing(**connection, component: "pdf_vision_processing", verification: :synthetic_pdf_vision, processing_mode: :vision)
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
        probe_endpoint = config_endpoint(provider: :openai_compatible, base_url: endpoint, api_key: access_token, exact_base_url: true)
        probe_model = Ai::Config::Model.new(endpoint: probe_endpoint, name: model)
        returned = Ai::Transport.for(probe_endpoint).probe(probe_model, :embedding, timeout:)
        raise Failure, :dimensions_mismatch unless returned == dimensions
      end
    end

    private

      # The synthetic statement through ReadPdf on a one-entry plan, the production path:
      # its text layer, or for the vision check the page as an image (the PDF itself on Anthropic,
      # which reads PDFs natively).
      def pdf_processing(provider:, endpoint:, access_token:, model:, component:, verification:, processing_mode:)
        run(
          component: component,
          provider_key: provider,
          endpoint: endpoint,
          model: model,
          credential: access_token,
          verification: verification
        ) do
          raise_unsupported_provider!(provider)
          config = config_endpoint(provider:, base_url: endpoint, api_key: access_token)
          route_model = Ai::Config::Model.new(endpoint: config, name: model, capabilities: %i[structured_output vision documents],
                                              max_output_tokens: production_pdf_output_tokens(provider:, endpoint:, model:))
          plan = Ai::Plan.new(feature: :extract_pdf, lane: :prompt, routes: [ Ai::Route.new(feature: :extract_pdf, model: route_model) ])
          units =
            if processing_mode == :text then [ Ai::PdfReading::Unit.text(Pdf::TextExtractor.pages(SyntheticPdf.bytes).join("\n"), page: 1) ]
            elsif provider.to_sym == :anthropic then [ Ai::PdfReading::Unit.pdf(1) ]
            else [ Ai::PdfReading::Unit.page(1) ]
            end

          value = Timeout.timeout(timeout) do
            Ai::Generations::ReadPdf.new(units:, content: SyntheticPdf.bytes, family: nil).call(batches: 1, plan:, down_marks: false).value!
          rescue Pdf::PageImages::Error => error
            raise Failure, error.code   # :missing_binary and the like, not a generic request failure
          end
          raise Failure, :invalid_response unless SyntheticPdf.valid_result?(value)
        end
      end

      # The probe must fit what the production `extract_pdf` route asks of the same model, not
      # an arbitrary smaller answer: a route's own output limit is part of the request it makes.
      # An ad-hoc probe of a server Sure hasn't configured keeps the conservative fallback.
      def production_pdf_output_tokens(provider:, endpoint:, model:)
        plan = Ai::Router.new(family: nil).resolve(:extract_pdf)
        return PDF_MAX_RESPONSE_TOKENS unless plan.is_a?(Ai::Plan)

        configured = configured_endpoint(provider.to_sym)
        return PDF_MAX_RESPONSE_TOKENS if configured.nil? || (endpoint.present? && !Ai::Transport::Http.same_url?(endpoint, configured.base_url))

        route = plan.routes.find { _1.model.endpoint.name == configured.name && _1.model.name == model }
        limit = route&.model&.max_output_tokens.to_i
        limit.positive? ? limit : PDF_MAX_RESPONSE_TOKENS
      end

      def run(component:, provider_key:, endpoint: nil, model: nil, credential: nil, dimensions: nil, verification: nil)
        key = cache_key(component:, provider_key:, endpoint:, model:, credential:, dimensions:, verification:)
        return stored(key) unless @run

        @results[key] = perform(component:, provider_key:, endpoint:, model:) { yield }
      end

      def stored(key)
        json = Ai::SharedState.read(key)
        json ? Result.from_json(json) : self.class.not_checked
      rescue StandardError => error
        record_store_failure(error)
        self.class.not_checked
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

      # The endpoint the feature's own calls use, from Ai::Config, with the URL and key AiHealth
      # resolved and the probe's timeout. Only a probe of a server Ai::Config doesn't know (an
      # admin's ad-hoc check, or a test) builds one from those values alone.
      # The endpoint's own API choice stands unless the caller picks one (the tool-call probe).
      def config_endpoint(provider:, base_url:, api_key:, responses_api: nil, exact_base_url: nil)
        configured = configured_endpoint(provider.to_sym)
        overrides = { base_url:, api_key:, timeout_seconds: timeout, max_retries: 0 }
        overrides[:responses_api] = responses_api unless responses_api.nil?
        overrides[:exact_base_url] = exact_base_url unless exact_base_url.nil?
        return configured.with(**overrides) if configured

        protocol = provider.to_sym == :anthropic ? :anthropic : :compatible
        Ai::Config::Endpoint.new(name: provider.to_s, protocol:, extra_headers: {}, **overrides)
      end

      def configured_endpoint(provider)
        config = Ai::Config.current
        case provider
        when :anthropic then config.endpoint(:anthropic)
        when :openai then config.endpoint(:openai) || config.endpoint(:openai_compatible)
        when :openai_compatible then config.embedding_model&.endpoint
        end
      end

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

      # The configured endpoint's static headers count too, so a changed gateway credential
      # header isn't answered from the cache.
      def cache_key(component:, provider_key:, endpoint:, model:, credential:, dimensions:, verification:)
        headers = configured_endpoint(provider_key.to_s.to_sym)&.extra_headers.to_h.sort.to_json
        fingerprint = Digest::SHA256.hexdigest(
          [ component, provider_key, endpoint, model, credential, dimensions, verification, headers ].join("\0")
        )
        "#{CACHE_NAMESPACE}/#{fingerprint}"
      end

      def timeout = Probe.timeout

      # Map a probe error to a machine-readable code for the admin AI status
      # page. Prefers an explicit `failure_code` the error carries (e.g. a
      # provider raising for a specific reason like a missing renderer binary),
      # then classifies Faraday/Timeout errors as :timeout, and falls back to
      # :request_failed for everything else.
      def failure_code(error)
        code = error.failure_code if error.respond_to?(:failure_code)
        return code if code

        # The vector store and PDF probes call client gems directly, whose errors aren't mapped yet.
        case Ai::Error.from_exception(error) || error
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
          endpoint: Ai::Instrumentation::Redactor.url(endpoint),
          model: model,
          failure_code: result.failure_code,
          exception_class: error.class.name,
          http_status: result.http_status,
          process_identity: WorkerAiHealth.current_process_identity
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

      def record_store_failure(error)
        message = "AI health probe store failed"
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
