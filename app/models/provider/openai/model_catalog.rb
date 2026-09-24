require "net/http"
require "uri"
require "json"

# Lists the models an OpenAI-compatible endpoint serves via GET <base>/models
# (GET <base>/models/user on OpenRouter).
# Works against OpenAI, OpenRouter, Ollama, LM Studio, LiteLLM and gateways
# such as OpenClaw. Every failure (HTTP status, bad payload, TLS, timeouts)
# surfaces as Error so callers can show a message instead of a 500.
class Provider::Openai::ModelCatalog
  Error = Class.new(StandardError)
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

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
      http.request(request)
    end

    raise Error, "#{error_subject} returned HTTP #{response.code}." unless response.is_a?(Net::HTTPSuccess)

    payload = JSON.parse(response.body)
    entries = payload.is_a?(Hash) ? payload["data"] : nil
    unless entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(Hash) }
      raise Error, "#{error_subject} returned an invalid response."
    end

    entries.filter_map do |model|
      id = model["id"].to_s
      next if id.blank?

      { id: id, label: label_for(id) }
    end.uniq { |model| model[:id] }
  rescue JSON::ParserError, URI::InvalidURIError => e
    raise Error, "#{error_subject} returned an invalid response: #{e.message}"
  rescue *CONNECTION_ERRORS => e
    raise Error, "#{error_subject} is unavailable: #{e.message}"
  end

  private
    def models_uri
      uri = URI(@uri_base)
      raise URI::InvalidURIError, "only HTTP and HTTPS endpoints are supported" unless uri.is_a?(URI::HTTP)

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

    def label_for(id)
      id
    end

    def error_subject
      "Model discovery"
    end
end
