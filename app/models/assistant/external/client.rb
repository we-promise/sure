require "net/http"
require "uri"
require "json"

class Assistant::External::Client
  TIMEOUT_CONNECT = 10   # seconds
  TIMEOUT_READ    = 120  # seconds (agent may take time to reason + call tools)

  def initialize(url:, token:, agent_id: "main")
    @url = url
    @token = token
    @agent_id = agent_id
  end

  # Streams text chunks from an OpenAI-compatible chat completions endpoint.
  #
  # messages - Array of {role:, content:} hashes (conversation history)
  # user     - Optional user identifier for session persistence
  # block    - Called with each text chunk as it arrives
  #
  # Returns the model identifier string from the response (e.g., "openclaw:buster").
  def chat(messages:, user: nil, &block)
    uri = URI(@url)
    http = build_http(uri)
    request = build_request(uri, messages, user)

    model = nil
    buffer = ""

    http.request(request) do |response|
      unless response.is_a?(Net::HTTPSuccess)
        raise Assistant::Error, "External assistant returned HTTP #{response.code}: #{response.body}"
      end

      response.read_body do |chunk|
        buffer += chunk

        while (line_end = buffer.index("\n"))
          line = buffer.slice!(0..line_end).strip
          next if line.empty?
          next unless line.start_with?("data:")

          data = line.delete_prefix("data:")
          data = data.delete_prefix(" ") # SSE spec: strip one optional leading space
          break if data == "[DONE]"

          parsed = parse_sse_data(data)
          next unless parsed

          model ||= parsed["model"]
          content = parsed.dig("choices", 0, "delta", "content")
          block.call(content) if content.present?
        end
      end
    end

    model
  end

  private

    def build_http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = TIMEOUT_CONNECT
      http.read_timeout = TIMEOUT_READ
      http
    end

    def build_request(uri, messages, user)
      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{@token}"
      request["Accept"] = "text/event-stream"
      request["x-openclaw-agent-id"] = @agent_id

      payload = {
        model: "openclaw:#{@agent_id}",
        messages: messages,
        stream: true
      }
      payload[:user] = user if user.present?

      request.body = payload.to_json
      request
    end

    def parse_sse_data(data)
      JSON.parse(data)
    rescue JSON::ParserError => e
      Rails.logger.warn("[External::Client] Unparseable SSE data: #{e.message}")
      nil
    end
end
