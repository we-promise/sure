require "net/http"
require "uri"
require "json"

class Assistant::External::ModelCatalog
  Error = Class.new(StandardError)
  CONNECTION_ERRORS = [
    *Assistant::External::Client::TRANSIENT_ERRORS,
    Timeout::Error,
    OpenSSL::SSL::SSLError,
    IOError,
    SystemCallError
  ].freeze

  def initialize(url:, token:, open_timeout: 5, read_timeout: 10)
    @url = url
    @token = token
    @open_timeout = open_timeout
    @read_timeout = read_timeout
  end

  def models
    uri = models_uri
    request = Net::HTTP::Get.new(uri.request_uri)
    request["Authorization"] = "Bearer #{@token}"
    request["Accept"] = "application/json"

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
      http.request(request)
    end

    raise Error, "Agent discovery returned HTTP #{response.code}." unless response.is_a?(Net::HTTPSuccess)

    payload = JSON.parse(response.body)
    entries = payload.is_a?(Hash) ? payload["data"] : nil
    unless entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(Hash) }
      raise Error, "Agent discovery returned an invalid response."
    end

    entries.filter_map do |model|
      id = model["id"].to_s
      next if id.blank?

      { id: id, label: agent_label(id) }
    end
  rescue JSON::ParserError, URI::InvalidURIError => e
    raise Error, "Agent discovery returned an invalid response: #{e.message}"
  rescue *CONNECTION_ERRORS => e
    raise Error, "Agent discovery is unavailable: #{e.message}"
  end

  private
    def models_uri
      uri = URI(@url)
      raise URI::InvalidURIError, "only HTTP and HTTPS endpoints are supported" unless uri.is_a?(URI::HTTP)

      path = uri.path.sub(%r{/chat/completions/?\z}, "/models")
      raise URI::InvalidURIError, "endpoint must end in /chat/completions" if path == uri.path

      uri.path = path
      uri.query = nil
      uri.fragment = nil
      uri
    end

    def agent_label(id)
      case id
      when "openclaw", "openclaw/default"
        I18n.t("assistant.external.model_catalog.default_agent_label", id: id)
      when %r{\Aopenclaw/(.+)\z}
        I18n.t("assistant.external.model_catalog.named_agent_label", name: $1, id: id)
      else id
      end
    end
end
