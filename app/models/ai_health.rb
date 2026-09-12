# frozen_string_literal: true

require "uri"

# Snapshot of AI configuration and bounded, non-destructive liveness checks for
# operators diagnosing chat, PDF import, and document-search failures.
class AiHealth
  OPENAI_DEFAULT_ENDPOINT = "https://api.openai.com/v1".freeze
  ANTHROPIC_DEFAULT_ENDPOINT = "https://api.anthropic.com".freeze
  OPENAI_COMPATIBLE_PROVIDER_DOMAINS = {
    openrouter: %w[openrouter.ai],
    together: %w[together.ai together.xyz],
    kilo: %w[kilo.ai],
    cloudflare: %w[api.cloudflare.com gateway.ai.cloudflare.com]
  }.freeze

  attr_reader :selected_llm_provider, :effective_llm_provider, :llm_model,
              :llm_endpoint, :llm_request_timeout, :probe_request_timeout, :openai_endpoint, :vector_store_adapter,
              :embedding_endpoint, :embedding_model, :embedding_dimensions,
              :pgvector_extension_available, :pgvector_extension_enabled,
              :pgvector_table_available, :qdrant_endpoint, :llm_probe,
              :function_calling_probe, :pdf_text_extraction_probe,
              :pdf_vision_processing_probe, :vector_store_probe, :embedding_probe

  # probe_cache lets a caller isolate where probe results are cached. The web
  # admin page shares the default `Rails.cache`-backed probe cache so repeat
  # page loads within the TTL don't re-hit providers; worker-originated
  # verification (see WorkerAiHealthCheckJob) passes an isolated store so its
  # results can never be served back to a web request, and vice versa (#3169).
  def initialize(run_probes: true, force_probes: false, probe_cache: Rails.cache)
    @run_probes = run_probes
    @force_probes = force_probes
    @probe_cache = probe_cache
    load_llm_status
    load_vector_store_status
    load_probes
  end

  def openai_credentials_configured?
    @openai_credentials_configured
  end

  def anthropic_credentials_configured?
    @anthropic_credentials_configured
  end

  def llm_configured?
    @llm_provider.present?
  end

  def llm_status
    return :not_configured unless llm_configured?

    llm_probe.status
  end

  # The assistant only answers through function calls, so an endpoint that
  # serves plain chat but rejects the `tools` parameter still cannot power it.
  # The probe confirms which of the two happened before reporting, so a model
  # is only ever blamed for a refusal the service actually made.
  def function_calling_status
    return :unavailable unless llm_configured?
    return :not_checked unless run_probes?
    return :supported if function_calling_probe.passing?
    return :not_used if function_calling_probe.failure_code == :no_tool_call
    return :unsupported if function_calling_probe.failure_code == :tools_refused

    :failing
  end

  def llm_fallback?
    @effective_llm_protocol.present? && @effective_llm_protocol != @selected_llm_protocol
  end

  def openai_compatible_endpoint?
    @openai_custom_endpoint
  end

  def pdf_text_extraction_supported?
    @pdf_text_extraction_capable == true && pdf_text_extraction_probe.passing?
  end

  def pdf_text_extraction_status
    pdf_probe_status(pdf_text_extraction_probe, capable: @pdf_text_extraction_capable)
  end

  def pdf_vision_processing_supported?
    @pdf_vision_processing_capable == true && pdf_vision_processing_probe.passing?
  end

  def pdf_vision_processing_status
    pdf_probe_status(pdf_vision_processing_probe, capable: @pdf_vision_processing_capable)
  end

  def vector_store_configured?
    @vector_store_configured
  end

  def vector_store_status
    return :missing if vector_store_adapter.nil?
    return :scaffolded if vector_store_adapter == :qdrant
    return :not_checked unless run_probes?
    return :failing if vector_store_probe.failing?
    return :not_configured unless vector_store_configured?
    return :failing unless vector_store_probe.passing?
    return :failing if vector_store_adapter == :pgvector && !embedding_probe.passing?

    :passing
  end

  def vector_store_failure_kind
    return unless vector_store_adapter == :pgvector
    return unless vector_store_status == :failing

    failure_codes = [ vector_store_probe.failure_code, embedding_probe.failure_code ].compact
    return :pgvector_extension_not_enabled if failure_codes.include?(:extension_not_enabled)
    return :pgvector_table_not_found if failure_codes.include?(:table_not_found)
    return :embedding_dimensions_mismatch if failure_codes.include?(:dimensions_mismatch)
    return :pgvector_probe_failed if vector_store_probe.failing?
    return :embedding_probe_timeout if failure_codes.include?(:timeout) && embedding_probe.failing?
    return :embedding_probe_failed if embedding_probe.failing?

    :vector_probe_failed
  end

  def openai_vector_store_uses_custom_endpoint?
    vector_store_adapter == :openai && @openai_custom_endpoint
  end

  def last_checked_at
    [ llm_probe, function_calling_probe, pdf_text_extraction_probe, pdf_vision_processing_probe, vector_store_probe,
      embedding_probe ]
      .filter_map(&:checked_at)
      .max
  end

  def self.redact_endpoint(value)
    return if value.blank?

    uri = URI.parse(value.to_s)
    uri.user = nil if uri.respond_to?(:user=)
    uri.password = nil if uri.respond_to?(:password=)
    uri.query = nil if uri.respond_to?(:query=)
    uri.fragment = nil if uri.respond_to?(:fragment=)
    uri.to_s
  rescue URI::InvalidURIError
    value.to_s
         .sub(%r{\A([^:]+://)[^/@]+@}, "\\1")
         .split(/[?#]/, 2)
         .first
  end

  private
    def load_llm_status
      @selected_llm_protocol = normalized_llm_provider(Setting.llm_provider)
      @openai_custom_endpoint = openai_uri_base.present? && !hosted_openai_endpoint?(openai_uri_base)
      @selected_llm_provider = selected_provider_name(@selected_llm_protocol)
      @openai_credentials_configured = safely(false) { Provider::Openai.configured? }
      @anthropic_credentials_configured = safely(false) { Provider::Anthropic.configured? }
      @llm_provider = safely(nil) { Provider::Registry.preferred_llm_provider }
      @effective_llm_protocol = protocol_name(@llm_provider)
      @effective_llm_provider = effective_provider_name(@effective_llm_protocol)

      provider_for_details = @effective_llm_protocol || @selected_llm_protocol
      @llm_model = effective_model(provider_for_details)
      @llm_endpoint = endpoint(provider_for_details)
      @llm_request_timeout = request_timeout(provider_for_details)
      @probe_request_timeout = probe_request_timeout_value
      @openai_uses_responses_endpoint = @effective_llm_protocol == :openai &&
        safely(false) { @llm_provider.supports_responses_endpoint? }
      @pdf_processing_capable = safely(false) do
        @llm_provider&.supports_pdf_processing?(model: llm_model)
      end
      @pdf_text_extraction_capable = @pdf_processing_capable && @effective_llm_protocol == :openai
      @pdf_vision_processing_capable = @pdf_processing_capable

      @openai_endpoint = redact_endpoint(openai_uri_base.presence || OPENAI_DEFAULT_ENDPOINT)
      @llm_access_token = access_token(@effective_llm_protocol)
      @llm_raw_endpoint = raw_endpoint(@effective_llm_protocol).presence || default_endpoint(@effective_llm_protocol)
    end

    def load_vector_store_status
      @vector_store_adapter = safely(nil) { VectorStore::Registry.adapter_name }
      @vector_store_configured = safely(false) { VectorStore.configured? }

      case vector_store_adapter
      when :pgvector
        load_pgvector_status
        @embedding_model = VectorStore.embedding_model
        @embedding_dimensions = VectorStore.embedding_dimensions
        @embedding_raw_endpoint = VectorStore.embedding_uri_base
        @embedding_endpoint = redact_endpoint(@embedding_raw_endpoint)
        @embedding_access_token = VectorStore.embedding_access_token
      when :qdrant
        @qdrant_endpoint = redact_endpoint(ENV.fetch("QDRANT_URL", "http://localhost:6333"))
      end
    end

    def load_probes
      @llm_probe = llm_configured? ? Probe.not_checked : Probe.not_configured
      @function_calling_probe = llm_configured? ? Probe.not_checked : Probe.not_configured
      @pdf_text_extraction_probe = llm_configured? && @pdf_text_extraction_capable ? Probe.not_checked : Probe.not_configured
      @pdf_vision_processing_probe = llm_configured? && @pdf_vision_processing_capable ? Probe.not_checked : Probe.not_configured
      @vector_store_probe = vector_store_adapter.present? ? Probe.not_checked : Probe.not_configured
      @embedding_probe = vector_store_adapter == :pgvector ? Probe.not_checked : Probe.not_configured
      return unless run_probes?

      probe = Probe.new(force: @force_probes, cache: @probe_cache)
      if llm_configured?
        @llm_probe = probe.llm(
          provider: @effective_llm_protocol,
          endpoint: @llm_raw_endpoint,
          access_token: @llm_access_token,
          model: llm_model,
          openai_compatible: @effective_llm_protocol == :openai && openai_compatible_endpoint?
        )
        @function_calling_probe = probe.function_calling(
          provider: @effective_llm_protocol,
          endpoint: @llm_raw_endpoint,
          access_token: @llm_access_token,
          model: llm_model,
          use_responses_endpoint: @openai_uses_responses_endpoint
        )
        if @pdf_text_extraction_capable
          @pdf_text_extraction_probe = probe.pdf_text_extraction(
            provider: @effective_llm_protocol,
            endpoint: @llm_raw_endpoint,
            access_token: @llm_access_token,
            model: llm_model,
            openai_compatible: openai_compatible_endpoint?
          )
        end
        if @pdf_vision_processing_capable
          @pdf_vision_processing_probe = probe.pdf_vision_processing(
            provider: @effective_llm_protocol,
            endpoint: @llm_raw_endpoint,
            access_token: @llm_access_token,
            model: llm_model,
            openai_compatible: @effective_llm_protocol == :openai && openai_compatible_endpoint?
          )
        end
      end

      case vector_store_adapter
      when :openai
        if vector_store_configured?
          @vector_store_probe = probe.openai_vector_store(
            endpoint: openai_uri_base.presence || OPENAI_DEFAULT_ENDPOINT,
            access_token: openai_access_token
          )
        end
      when :pgvector
        @vector_store_probe = probe.pgvector
        @embedding_probe = probe.embedding(
          endpoint: @embedding_raw_endpoint,
          access_token: @embedding_access_token,
          model: embedding_model,
          dimensions: embedding_dimensions
        )
      end
    end

    def run_probes?
      @run_probes
    end

    def pdf_probe_status(probe, capable:)
      return :unavailable unless llm_configured?
      return :unsupported unless capable
      return :not_checked unless run_probes?

      probe.passing? ? :supported : :failing
    end

    def load_pgvector_status
      connection = ActiveRecord::Base.connection
      @pgvector_table_available = connection.table_exists?(VectorStore::Pgvector::TABLE_NAME)
      @pgvector_extension_enabled = connection.extension_enabled?("vector")
      @pgvector_extension_available = @pgvector_extension_enabled || connection.select_value(
        "SELECT 1 FROM pg_available_extensions WHERE name = 'vector' LIMIT 1"
      ).present?
    rescue StandardError
      @pgvector_table_available = false
      @pgvector_extension_enabled = false
      @pgvector_extension_available = false
    end

    def normalized_llm_provider(value)
      value.to_s == "anthropic" ? :anthropic : :openai
    end

    def protocol_name(provider)
      case provider
      when Provider::Openai then :openai
      when Provider::Anthropic then :anthropic
      end
    end

    def selected_provider_name(protocol)
      protocol == :openai && @openai_custom_endpoint ? :openai_compatible : protocol
    end

    def effective_provider_name(protocol)
      return protocol unless protocol == :openai
      return :openai unless @openai_custom_endpoint

      openai_compatible_provider_name(openai_uri_base)
    end

    def openai_compatible_provider_name(value)
      uri = URI.parse(value.to_s)
      host = uri.host.to_s.downcase

      return :ollama if ollama_endpoint?(uri, host)

      OPENAI_COMPATIBLE_PROVIDER_DOMAINS.each do |provider, domains|
        return provider if domains.any? { |domain| host == domain || host.end_with?(".#{domain}") }
      end

      :custom_openai_compatible
    rescue URI::InvalidURIError
      :custom_openai_compatible
    end

    def ollama_endpoint?(uri, host)
      uri.port == 11_434 || host == "ollama" || host.end_with?(".ollama")
    end

    def effective_model(provider)
      case provider
      when :anthropic then Provider::Anthropic.effective_model
      else Provider::Openai.effective_model
      end
    end

    def endpoint(provider)
      value = raw_endpoint(provider)
      redact_endpoint(value.presence || default_endpoint(provider))
    end

    def default_endpoint(provider)
      provider == :anthropic ? ANTHROPIC_DEFAULT_ENDPOINT : OPENAI_DEFAULT_ENDPOINT
    end

    def raw_endpoint(provider)
      provider == :anthropic ? anthropic_base_url : openai_uri_base
    end

    def access_token(provider)
      if provider == :anthropic
        ENV["ANTHROPIC_ACCESS_TOKEN"].presence ||
          ENV["ANTHROPIC_API_KEY"].presence ||
          Setting.anthropic_access_token
      else
        openai_access_token
      end
    end

    def openai_access_token
      ENV["OPENAI_ACCESS_TOKEN"].presence || Setting.openai_access_token
    end

    # Reports the timeout used by normal LLM requests for the selected provider.
    def request_timeout(provider)
      if provider == :anthropic
        ENV.fetch("ANTHROPIC_REQUEST_TIMEOUT", 600).to_i
      else
        Provider::Openai.request_timeout
      end
    end

    # Timeout applied to the admin "live checks" probes. Delegates to
    # Probe.timeout so System Health reports the exact bound the probes use,
    # guaranteeing the two can never drift. Deliberately distinct from
    # request_timeout, which bounds the LLM calls the app makes during
    # normal use (chat, PDF import).
    def probe_request_timeout_value
      Probe.timeout
    end

    def openai_uri_base
      ENV["OPENAI_URI_BASE"].presence || Setting.openai_uri_base
    end

    def anthropic_base_url
      ENV["ANTHROPIC_BASE_URL"].presence || Setting.anthropic_base_url
    end

    def hosted_openai_endpoint?(value)
      uri = URI.parse(value.to_s)
      normalized_path = uri.path.to_s.sub(%r{/+\z}, "")

      uri.scheme == "https" && uri.host == "api.openai.com" && uri.port == 443 && normalized_path.in?([ "", "/v1" ])
    rescue URI::InvalidURIError
      false
    end

    def redact_endpoint(value)
      self.class.redact_endpoint(value)
    end

    def safely(fallback)
      yield
    rescue StandardError
      fallback
    end
end
