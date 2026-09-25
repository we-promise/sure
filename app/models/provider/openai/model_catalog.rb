require "net/http"
require "uri"
require "json"

# Lists the models an OpenAI-compatible endpoint serves via GET <base>/models
# (GET <base>/models/user on OpenRouter).
# Works against OpenAI, OpenRouter, Ollama, LM Studio, LiteLLM and gateways
# such as OpenClaw. Every failure (HTTP status, bad payload, TLS, timeouts)
# surfaces as Error so callers can show a message instead of a 500.
class Provider::Openai::ModelCatalog
  # kind is one of :http_status, :invalid_response, :invalid_url, :unavailable;
  # status is the HTTP status for :http_status. Callers use them to pick a
  # short hint instead of showing the full message.
  class Error < StandardError
    attr_reader :kind, :status

    def initialize(message = nil, kind: nil, status: nil)
      super(message)
      @kind = kind
      @status = status
    end
  end

  DEFAULT_URI_BASE = "https://api.openai.com/v1".freeze
  CONNECTION_ERRORS = [
    Net::OpenTimeout,
    Net::ReadTimeout,
    Errno::ECONNREFUSED,
    Errno::ECONNRESET,
    Errno::EHOSTUNREACH,
    SocketError,
    Timeout::Error,
    OpenSSL::SSL::SSLError,
    IOError,
    SystemCallError
  ].freeze

  # uri_base is the API base the chat client uses (e.g. https://openrouter.ai/api/v1).
  def initialize(uri_base:, token:, open_timeout: 5, read_timeout: 10)
    @uri_base = uri_base.presence || DEFAULT_URI_BASE
    @token = token
    @open_timeout = open_timeout
    @read_timeout = read_timeout
  end

  # Returns [{ id:, label: }] in the order the endpoint lists them.
  def models
    uri = models_uri
    request = Net::HTTP::Get.new(uri.request_uri)
    request["Authorization"] = "Bearer #{@token}" if @token.present?
    request["Accept"] = "application/json"
    extra_headers.each { |name, value| request[name] = value }

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
      http.request(request)
    end

    unless response.is_a?(Net::HTTPSuccess)
      raise Error.new(error_text(:http_status, status: response.code), kind: :http_status, status: response.code)
    end

    payload = JSON.parse(response.body)
    entries = payload.is_a?(Hash) ? payload["data"] : nil
    unless entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(Hash) }
      raise Error.new(error_text(:invalid_response), kind: :invalid_response)
    end

    entries.filter_map do |model|
      capabilities = model["capabilities"]
      next if capabilities.is_a?(Hash) && capabilities["chat_completion"] == false

      id = model["id"].to_s
      next if id.blank?

      { id: id, label: label_for(id) }
    end.uniq { |model| model[:id] }
  rescue URI::InvalidURIError => e
    raise Error.new(error_text(:invalid_response_detail, detail: e.message), kind: :invalid_url)
  rescue JSON::ParserError => e
    raise Error.new(error_text(:invalid_response_detail, detail: e.message), kind: :invalid_response)
  rescue *CONNECTION_ERRORS => e
    raise Error.new(error_text(:unavailable, detail: e.message), kind: :unavailable)
  end

  private
    def models_uri
      uri = http_uri(@uri_base)
      uri.path = "#{uri.path.chomp('/')}/#{openrouter?(uri) ? 'models/user' : 'models'}"
      uri.query = nil
      uri.fragment = nil
      uri
    end

    # OpenRouter's /models is its whole catalog. /models/user is the same list
    # filtered by the key's provider preferences, privacy settings and
    # guardrails (and region, on regional hosts), so it only offers models the
    # key can actually use.
    def openrouter?(uri)
      host = uri.host.to_s.downcase
      host == "openrouter.ai" || host.end_with?(".openrouter.ai")
    end

    # Parses an absolute http(s) URL with a host. Rejects values URI accepts
    # but Net::HTTP can't use, such as "http:foo" (no host, nil path) or
    # "http:/foo" (no host).
    def http_uri(value)
      uri = URI(value.to_s.strip)
      unless uri.is_a?(URI::HTTP) && uri.host.present? && !uri.opaque
        raise URI::InvalidURIError, I18n.t("provider.openai.model_catalog.errors.invalid_url")
      end

      uri.path = uri.path.to_s
      uri
    end

    # Static OPENAI_EXTRA_HEADERS, so gateways that route or authenticate on a
    # header accept discovery too. Session-scoped values ({session_id}) only
    # resolve inside a chat, so they are left out.
    def extra_headers
      Provider::Openai.extra_headers.reject { |_, value| value.include?("{session_id}") }
    end

    def label_for(id)
      id
    end

    def error_text(kind, **options)
      I18n.t("#{i18n_scope}.errors.#{kind}", **options)
    end

    def i18n_scope
      "provider.openai.model_catalog"
    end
end
