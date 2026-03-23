require "net/http"
require "uri"
require "json"
require "socket"
require "openssl"
require "websocket/driver"

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
    SocketError,
    IO::TimeoutError
  ].freeze

  # Minimal IO wrapper that satisfies WebSocket::Driver::Client's interface.
  # The driver calls #url to build the handshake and #write to send frames.
  class WsIO
    attr_reader :url

    def initialize(uri, socket)
      @url = uri.to_s
      @socket = socket
    end

    def write(data)
      @socket.write(data)
    end
  end

  def initialize(url:, token:, agent_id: "main", session_key: "agent:main:main")
    @url = url
    @token = token # pipelock:ignore Credential in URL
    @agent_id = agent_id
    @session_key = session_key
  end

  # Streams text chunks from an OpenAI-compatible chat endpoint.
  #
  # messages - Array of {role:, content:} hashes (conversation history)
  # user     - Optional user identifier for session persistence
  # block    - Called with each text chunk as it arrives
  #
  # Returns the model identifier string from the response.
  def chat(messages:, user: nil, &block)
    uri = URI(@url)
    retries = 0
    streaming_started = false

    begin
      model = case uri.scheme
      when "ws", "wss"
        ws_chat(uri, messages, user) do |content|
          streaming_started = true
          block.call(content)
        end
      when "http", "https"
        http_chat(uri, messages, user) do |content|
          streaming_started = true
          block.call(content)
        end
      else
        raise Assistant::Error, "Unsupported URL scheme: #{uri.scheme}. Use http(s) or ws(s)."
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

    # -- HTTP/SSE transport ------------------------------------------------

    def http_chat(uri, messages, user, &block)
      request = build_request(uri, messages, user)
      http = build_http(uri)
      stream_response(http, request, &block)
    end

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
        http = Net::HTTP.new(uri.host, uri.port, proxy_uri.host, proxy_uri.port, proxy_uri.user, proxy_uri.password)
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

    # -- WebSocket transport -----------------------------------------------

    def ws_chat(uri, messages, user, &block)
      socket = open_ws_socket(uri)
      io = WsIO.new(uri, socket)
      driver = WebSocket::Driver::Client.new(io)

      driver.set_header("Authorization", "Bearer #{@token}")
      driver.set_header("X-Agent-Id", @agent_id)
      driver.set_header("X-Session-Key", @session_key)

      model = nil
      done = false
      error_message = nil

      driver.on(:open) do
        payload = build_ws_payload(messages, user)
        driver.text(payload.to_json)
      end

      driver.on(:message) do |event|
        result = process_ws_frame(event.data)
        next unless result

        if result[:done]
          done = true
          driver.close
        else
          model ||= result[:model]
          block.call(result[:content]) if result[:content]
        end
      end

      driver.on(:close) do |_event|
        done = true
      end

      driver.on(:error) do |event|
        error_message = event.message
        done = true
      end

      driver.start

      until done
        ready = IO.select([ socket ], nil, nil, TIMEOUT_READ)
        raise IO::TimeoutError, "WebSocket read timed out after #{TIMEOUT_READ}s" unless ready

        begin
          data = socket.readpartial(16_384)
          driver.parse(data)
        rescue EOFError
          break
        end
      end

      raise Assistant::Error, "WebSocket error: #{error_message}" if error_message

      model
    ensure
      socket&.close rescue nil
    end

    def open_ws_socket(uri)
      port = uri.port || (uri.scheme == "wss" ? 443 : 80)
      tcp = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM)
      sockaddr = Socket.sockaddr_in(port, uri.host)

      begin
        tcp.connect_nonblock(sockaddr)
      rescue IO::WaitWritable
        unless IO.select(nil, [ tcp ], nil, TIMEOUT_CONNECT)
          tcp.close
          raise Errno::ETIMEDOUT, "WebSocket connection timed out after #{TIMEOUT_CONNECT}s"
        end
        begin
          tcp.connect_nonblock(sockaddr)
        rescue Errno::EISCONN
          # Connected successfully
        end
      end

      if uri.scheme == "wss"
        ctx = OpenSSL::SSL::SSLContext.new
        ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
        ssl.hostname = uri.host # SNI
        ssl.connect
        ssl
      else
        tcp
      end
    end

    def build_ws_payload(messages, user)
      payload = {
        model: @agent_id,
        messages: messages,
        stream: true
      }
      payload[:user] = user if user.present?
      payload
    end

    def process_ws_frame(data)
      # Handle both SSE-formatted frames ("data: {json}") and raw JSON frames
      stripped = data.strip
      return nil if stripped.empty?

      if stripped.start_with?("data:")
        stripped = stripped.delete_prefix("data:")
        stripped = stripped.delete_prefix(" ")
      end

      return { done: true } if stripped == "[DONE]"

      parsed = parse_sse_data(stripped)
      return nil unless parsed

      {
        model: parsed["model"],
        content: parsed.dig("choices", 0, "delta", "content")
      }
    end

    # -- Shared helpers ----------------------------------------------------

    def parse_sse_data(data)
      JSON.parse(data)
    rescue JSON::ParserError => e
      Rails.logger.warn("[External::Client] Unparseable SSE data: #{e.message}")
      nil
    end
end
