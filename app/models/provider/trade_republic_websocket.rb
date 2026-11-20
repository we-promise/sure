require "json"
require "net/http"
require "openssl"
require "socket"
require "timeout"
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

  def connect
    tcp = Socket.tcp(HOST, 443, connect_timeout: @timeout)
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
