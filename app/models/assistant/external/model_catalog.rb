require "net/http"
require "uri"
require "json"

class Assistant::External::ModelCatalog
  Error = Class.new(StandardError)

  def initialize(url:, token:)
    @url = url
    @token = token
  end

  def models
    uri = models_uri
    request = Net::HTTP::Get.new(uri.request_uri)
    request["Authorization"] = "Bearer #{@token}"
    request["Accept"] = "application/json"

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 20) do |http|
      http.request(request)
    end

    raise Error, "Agent discovery returned HTTP #{response.code}." unless response.is_a?(Net::HTTPSuccess)

    payload = JSON.parse(response.body)
    Array(payload["data"]).filter_map do |model|
      id = model["id"].to_s
      next if id.blank?

      { id: id, label: agent_label(id) }
    end
  rescue JSON::ParserError, URI::InvalidURIError => e
    raise Error, "Agent discovery returned an invalid response: #{e.message}"
  rescue *Assistant::External::Client::TRANSIENT_ERRORS => e
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
      when "openclaw" then "Default agent (openclaw)"
      when "openclaw/default" then "Default agent (openclaw/default)"
      when %r{\Aopenclaw/(.+)\z} then "#{$1} (#{id})"
      else id
      end
    end
end
