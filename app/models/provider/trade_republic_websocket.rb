require "base64"
require "json"
require "net/http"
require "openssl"
require "socket"
require "timeout"
require "uri"
require "websocket/driver"

class Provider::TradeRepublicWebsocket
  HOST = "api.traderepublic.com"
  URL = "wss://#{HOST}"

  def initialize(headers:, timeout: 30)
    @headers = headers
    @timeout = timeout
    @messages = Queue.new
    @socket = nil
    @driver = nil
  end

  # Opens the TLS WebSocket connection, tunneling through the configured HTTP
  # proxy when one applies to the Trade Republic host.
  def connect
    tcp = open_tunnel
    @socket = tcp
    context = OpenSSL::SSL::SSLContext.new
    context.set_params
    @socket = OpenSSL::SSL::SSLSocket.new(tcp, context)
    @socket.hostname = HOST
    @socket.sync_close = true
    Timeout.timeout(@timeout, Timeout::Error) { @socket.connect }
    @socket.post_connection_check(HOST)

    adapter = SocketAdapter.new(@socket)
    @driver = WebSocket::Driver.client(adapter)
    @headers.each { |key, value| @driver.set_header(key, value) }
    @driver.on(:message) { |event| @messages << event.data }
    @driver.on(:error) { |event| raise Provider::TradeRepublicClient::ProviderUnavailable, event.message }
    @driver.start
    read_until { @driver.state == :open }
    self
  rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError => e
    close
    raise Provider::TradeRepublicClient::TransientProviderError, "Trade Republic WebSocket connection failed: #{e.class}"
  rescue Timeout::Error
    close
    raise Provider::TradeRepublicClient::Timeout, "Trade Republic WebSocket connection timed out"
  end

  def send_text(payload)
    @driver.text(payload)
  end

  def receive
    return @messages.pop(true) unless @messages.empty?

    loop do
      read_once
      return @messages.pop(true) unless @messages.empty?
    end
  rescue ThreadError
    retry
  rescue Timeout::Error
    raise Provider::TradeRepublicClient::Timeout, "Trade Republic WebSocket timed out"
  rescue EOFError, IOError => e
    raise Provider::TradeRepublicClient::TransientProviderError, "Trade Republic WebSocket closed unexpectedly: #{e.class}"
  end

  def close
    @driver&.close if @driver&.state == :open
    @socket&.close
  rescue IOError
    nil
  ensure
    @driver = nil
    @socket = nil
  end

  private

    PROXY_RESPONSE_LIMIT = 16_384

    # Connects directly, or establishes a CONNECT tunnel to HOST:443 through
    # the resolved proxy.
    def open_tunnel
      proxy = proxy_uri
      return Socket.tcp(HOST, 443, connect_timeout: @timeout) unless proxy

      socket = Socket.tcp(proxy.hostname, proxy.port, connect_timeout: @timeout)
      begin
        socket.write(connect_request(proxy))
        read_proxy_response(socket)
        socket
      rescue StandardError
        socket.close
        raise
      end
    end

    # Builds the CONNECT request, adding Basic proxy authentication when the
    # proxy URL carries credentials.
    def connect_request(proxy)
      request = +"CONNECT #{HOST}:443 HTTP/1.1\r\nHost: #{HOST}:443\r\n"
      if proxy.user
        credentials = "#{URI.decode_uri_component(proxy.user)}:#{URI.decode_uri_component(proxy.password.to_s)}"
        request << "Proxy-Authorization: Basic #{Base64.strict_encode64(credentials)}\r\n"
      end
      request << "\r\n"
    end

    # Resolves the proxy for the WSS endpoint, preferring HTTPS_PROXY and
    # falling back to HTTP_PROXY for deployments that only configure the latter.
    def proxy_uri
      proxy = find_proxy("https") || find_proxy("http")
      return unless proxy

      unless proxy.scheme == "http"
        raise Provider::TradeRepublicClient::ProviderUnavailable,
              "Unsupported Trade Republic WebSocket proxy scheme"
      end

      proxy
    rescue URI::Error
      raise Provider::TradeRepublicClient::ProviderUnavailable,
            "Invalid Trade Republic WebSocket proxy configuration"
    end

    # Resolves the scheme-specific proxy variable while preserving the URI
    # library's NO_PROXY and loopback handling.
    def find_proxy(scheme)
      URI.parse("#{scheme}://#{HOST}:443").find_proxy
    end

    # Reads and validates the proxy's CONNECT response, bounding its size and
    # requiring a 2xx status before the tunnel is used.
    def read_proxy_response(socket)
      response = +""
      Timeout.timeout(@timeout, Timeout::Error) do
        while response.bytesize < PROXY_RESPONSE_LIMIT
          response << socket.readpartial(1024)
          break if response.include?("\r\n\r\n")
        end
      end

      if response.bytesize >= PROXY_RESPONSE_LIMIT || !response.match?(/\AHTTP\/1\.[01] 2\d\d\b/)
        raise Provider::TradeRepublicClient::TransientProviderError,
              "Trade Republic WebSocket proxy rejected CONNECT"
      end

      response
    rescue EOFError, IOError => e
      raise Provider::TradeRepublicClient::TransientProviderError,
            "Trade Republic WebSocket proxy closed during CONNECT: #{e.class}"
    end

    def read_until
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
      until yield
        raise Timeout::Error if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        read_once
      end
    rescue Timeout::Error
      close
      raise Provider::TradeRepublicClient::Timeout, "Trade Republic WebSocket timed out"
    end

    def read_once
      ready = IO.select([ @socket ], nil, nil, @timeout)
      raise Timeout::Error unless ready

      @driver.parse(@socket.readpartial(64 * 1024))
    end

    class SocketAdapter
      attr_reader :url

      def initialize(socket)
        @socket = socket
        @url = URL
      end

      def write(data)
        @socket.write(data)
      end
    end
end
