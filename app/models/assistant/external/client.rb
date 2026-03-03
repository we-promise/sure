require "net/http"
require "uri"
require "json"

class Assistant::External::Client
  TIMEOUT_CONNECT = 10   # seconds
  TIMEOUT_READ    = 120  # seconds (agent may take time to reason + call tools)
  MAX_RETRIES     = 2
  RETRY_DELAY     = 1    # seconds (doubles each retry)
  MAX_SSE_BUFFER  = 1_048_576 # 1 MB safety cap on SSE buffer

  TRANSIENT_ERRORS = [
    Net::OpenTimeout,
    Net::ReadTimeout,
    Errno::ECONNREFUSED,
    Errno::ECONNRESET,
    Errno::EHOSTUNREACH,
    SocketError
  ].freeze

  def initialize(url:, token:, agent_id: "main", session_key: "agent:main:main")
    @url = url
    @token = token
    @agent_id = agent_id
    @session_key = session_key
  end

  # Streams text chunks from an OpenAI-compatible chat endpoint via SSE.
  #
  # messages - Array of {role:, content:} hashes (conversation history)
  # user     - Optional user identifier for session persistence
  # block    - Called with each text chunk as it arrives
  #
  # Returns the model identifier string from the response.
  def chat(messages:, user: nil, &block)
    uri = URI(@url)
    request = build_request(uri, messages, user)
    retries = 0
    streaming_started = false

    begin
      http = build_http(uri)
      model = stream_response(http, request) do |content|
        streaming_started = true
        block.call(content)
      end
      model
    rescue *TRANSIENT_ERRORS => e
      if streaming_started
        Rails.logger.warn("[External::Client] Stream interrupted: #{e.class} - #{e.message}")
        raise Assistant::Error, "External assistant connection was interrupted."
      end

      retries += 1
      if retries <= MAX_RETRIES
        Rails.logger.warn("[External::Client] Transient error (attempt #{retries}/#{MAX_RETRIES}): #{e.class} - #{e.message}")
        sleep(RETRY_DELAY * retries)
        retry
      end
      Rails.logger.error("[External::Client] Unreachable after #{MAX_RETRIES + 1} attempts: #{e.class} - #{e.message}")
      raise Assistant::Error, "External assistant is temporarily unavailable."
    end
  end

  private

    def stream_response(http, request, &block)
      model = nil
      buffer = +""
      done = false

      http.request(request) do |response|
        unless response.is_a?(Net::HTTPSuccess)
          Rails.logger.warn("[External::Client] Upstream HTTP #{response.code}: #{response.body.to_s.truncate(500)}")
          raise Assistant::Error, "External assistant returned HTTP #{response.code}."
        end

        response.read_body do |chunk|
          break if done
          buffer << chunk

          if buffer.bytesize > MAX_SSE_BUFFER
            raise Assistant::Error, "External assistant stream exceeded maximum buffer size."
          end

          while (line_end = buffer.index("\n"))
            line = buffer.slice!(0..line_end).strip
            next if line.empty?
            next unless line.start_with?("data:")

            data = line.delete_prefix("data:")
            data = data.delete_prefix(" ") # SSE spec: strip one optional leading space

            if data == "[DONE]"
              done = true
              break
            end

            parsed = parse_sse_data(data)
            next unless parsed

            model ||= parsed["model"]
            content = parsed.dig("choices", 0, "delta", "content")
            block.call(content) unless content.nil?
          end
        end
      end

      model
    end

    def build_http(uri)
      proxy_uri = resolve_proxy(uri)

      if proxy_uri
        http = Net::HTTP.new(uri.host, uri.port, proxy_uri.host, proxy_uri.port)
      else
        http = Net::HTTP.new(uri.host, uri.port)
      end

      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = TIMEOUT_CONNECT
      http.read_timeout = TIMEOUT_READ
      http
    end

    def resolve_proxy(uri)
      proxy_env = (uri.scheme == "https") ? "HTTPS_PROXY" : "HTTP_PROXY"
      proxy_url = ENV[proxy_env] || ENV[proxy_env.downcase]
      return nil if proxy_url.blank?

      no_proxy = ENV["NO_PROXY"] || ENV["no_proxy"]
      return nil if host_bypasses_proxy?(uri.host, no_proxy)

      URI(proxy_url)
    rescue URI::InvalidURIError => e
      Rails.logger.warn("[External::Client] Invalid proxy URL ignored: #{e.message}")
      nil
    end

    def host_bypasses_proxy?(host, no_proxy)
      return false if no_proxy.blank?
      host_down = host.downcase
      no_proxy.split(",").any? do |pattern|
        pattern = pattern.strip.downcase.delete_prefix(".")
        host_down == pattern || host_down.end_with?(".#{pattern}")
      end
    end

    def build_request(uri, messages, user)
      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{@token}"
      request["Accept"] = "text/event-stream"
      request["X-Agent-Id"] = @agent_id
      request["X-Session-Key"] = @session_key

      payload = {
        model: @agent_id,
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
