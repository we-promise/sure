require "test_helper"

# The interrupt Ai::Gate relies on, against a real socket: a request holding a place is stopped
# from another thread while the server is still reading its prompt (silent) and while it streams,
# directly and through a forward proxy, and the server sees the connection close, which is what
# frees a llama.cpp slot. Faraday's adapter and Net::HTTP's private `connect`/`@socket` are the
# seams it pins (Ai::Gate::Watched).
class Ai::GateInterruptTest < ActiveSupport::TestCase
  ai_capsule!
  # One HTTP/1.1 server connection per request. `silent` never answers; `streaming` sends
  # server-sent events until the client goes away. Each connection reports :request once the
  # request arrived and :closed once the client closed it.
  class StubServer
    attr_reader :port, :events

    def initialize(mode)
      @mode = mode
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @events = Queue.new
      @thread = Thread.new { loop { serve(@server.accept) } rescue IOError }
    end

    def url = "http://127.0.0.1:#{port}"

    def close
      @server.close
      @thread.join(2)
    end

    private
      def serve(client)
        Thread.new do
          read_request(client)
          @events << :request
          @mode == :silent ? wait_for_close(client) : stream_until_closed(client)
          @events << :closed
        ensure
          client.close
        end
      end

      def read_request(client)
        length = 0
        while (line = client.gets) && line != "\r\n"
          length = line.split(":", 2).last.to_i if line.downcase.start_with?("content-length:")
        end
        client.read(length) if length.positive?
      end

      def wait_for_close(client)
        client.read   # returns at EOF: the client shut or closed its side
      rescue SystemCallError, IOError
        nil
      end

      def stream_until_closed(client)
        client.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n")
        loop do
          event = "data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n"
          client.write("#{event.bytesize.to_s(16)}\r\n#{event}\r\n")
          client.flush
          sleep 0.05
        end
      rescue SystemCallError, IOError
        nil
      end
  end

  # A plain forward proxy for http:// targets: it reads the absolute-form request line, opens the
  # target and pipes both ways, and closes the target's connection when the client's closes.
  class StubProxy
    attr_reader :port

    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @thread = Thread.new { loop { relay(@server.accept) } rescue IOError }
    end

    def url = "http://127.0.0.1:#{port}"

    def close
      @server.close
      @thread.join(2)
    end

    private
      def relay(client)
        Thread.new do
          method, target, version = client.gets.split
          uri = URI(target)
          upstream = TCPSocket.new(uri.host, uri.port)
          upstream.write("#{method} #{uri.request_uri} #{version}\r\n")
          [ Thread.new { pipe(client, upstream) }, Thread.new { pipe(upstream, client) } ].each(&:join)
        ensure
          upstream&.close
          client.close
        end
      end

      def pipe(from, to)
        while (data = from.readpartial(16_384))
          to.write(data)
        end
      rescue SystemCallError, IOError, EOFError
        [ from, to ].each { _1.close_write rescue nil }
      end
  end

  # Real sockets, to the stub servers on 127.0.0.1 only.
  setup do
    open_loopback_sockets
    @servers = []
  end

  teardown do
    @servers.each(&:close)
    close_loopback_sockets
  end

  test "interrupts a request while the server is still reading the prompt" do
    assert_interrupted server(:silent)
  end

  test "interrupts a request while the answer streams" do
    assert_interrupted server(:streaming), streaming: true
  end

  test "interrupts a request through a forward proxy, and the proxy closes the server's connection" do
    proxy = StubProxy.new.tap { @servers << _1 }
    Ai::Transport::Http.stubs(:proxy_or_warn).returns(proxy.url)

    assert_interrupted server(:silent)
  end

  test "interrupts a streamed request through a forward proxy" do
    proxy = StubProxy.new.tap { @servers << _1 }
    Ai::Transport::Http.stubs(:proxy_or_warn).returns(proxy.url)

    assert_interrupted server(:streaming), streaming: true
  end

  test "a request interrupted before it connects is shut as soon as it does" do
    stub = server(:silent)
    holder = Ai::Gate::Holder.new(lane: :background)
    holder.interrupt

    error = assert_raises(Ai::Gate::Interrupted) { Ai::Gate.holding(holder) { post(stub) } }

    assert_kind_of Faraday::ConnectionFailed, error.cause
  end

  test "interrupts only its own request, though both share one Faraday connection" do
    stub = server(:streaming)
    connection = faraday(stub)
    interrupted = Ai::Gate::Holder.new(lane: :background)
    kept = Ai::Gate::Holder.new(lane: :prompt)
    chunks = Queue.new
    results = Queue.new

    threads = [ interrupted, kept ].map do |holder|
      Thread.new do
        Ai::Gate.holding(holder) { post(stub, connection:, on_data: ->(_) { chunks << holder }) }
      rescue StandardError => error
        results << [ holder, error ]
      end
    end
    2.times { assert_equal :request, stub.events.pop(timeout: 5) }
    streaming = Set.new
    Timeout.timeout(5) { streaming << chunks.pop until streaming.size == 2 }

    interrupted.interrupt
    holder, error = results.pop(timeout: 5)

    assert_same interrupted, holder
    assert_kind_of Ai::Gate::Interrupted, error
    assert_equal :closed, stub.events.pop(timeout: 5)
    chunks.clear
    assert_same kept, chunks.pop(timeout: 2), "the other request should still be streaming"
    assert threads.last.alive?
  ensure
    threads&.each { _1.kill.join(2) }
  end

  test "an error in a request that wasn't interrupted is raised as it is" do
    stub = server(:silent)
    stub.close
    holder = Ai::Gate::Holder.new(lane: :background)

    assert_raises(Faraday::ConnectionFailed) { Ai::Gate.holding(holder) { post(stub) } }
  end

  test "a local generation still streaming when its budget runs out raises Timeout and frees its place" do
    stub = server(:streaming)
    endpoint = ai_endpoint(name: "gpu", base_url: "#{stub.url}/v1", location: :local, timeout_seconds: 1)
    request = Ai::Transport::Base::Request.new(feature: :items, model: ai_model(endpoint:), instructions: "Name it.", input: "AMZN",
                                               schema: { type: "object" }, schema_name: "items", json_mode: :strict)
    # The error class, not wall-clock timing, proves the call's own budget ended it: under a loaded
    # full suite the streaming server's chunks can arrive a little late.
    assert_raises(Ai::Error::Timeout) { Timeout.timeout(5) { Ai::Transport.for(endpoint).generate(request) } }
    assert_equal :request, stub.events.pop(timeout: 1)
    assert_equal :closed, stub.events.pop(timeout: 2), "the server should see the connection close"
    assert_empty Ai::Sequencer.gate_for(endpoint).holders
  end

  test "with real sockets open, any host but 127.0.0.1 is refused" do
    error = assert_raises(ArgumentError) { Faraday.new(url: "http://llm.example.test") { _1.adapter Ai::Transport::Http::ProxyNetHttp }.get("/") }

    assert_includes error.message, "llm.example.test"
  end

  private
    def server(mode) = StubServer.new(mode).tap { @servers << _1 }

    def faraday(stub)
      Faraday.new(url: stub.url, request: { timeout: 10, open_timeout: 5 }) { _1.adapter Ai::Transport::Http::ProxyNetHttp }
    end

    def post(stub, connection: faraday(stub), on_data: nil)
      connection.post("/v1/chat/completions", "{}") do |request|
        request.options.on_data = ->(chunk, _bytes, _env = nil) { on_data&.call(chunk) } if on_data
      end
    end

    def assert_interrupted(stub, streaming: false)
      holder = Ai::Gate::Holder.new(lane: :background)
      chunks = Queue.new
      result = Queue.new
      thread = Thread.new do
        Ai::Gate.holding(holder) { post(stub, on_data: (->(chunk) { chunks << chunk } if streaming)) }
        result << :finished
      rescue StandardError => error
        result << error
      end

      assert_equal :request, stub.events.pop(timeout: 5)
      assert chunks.pop(timeout: 5), "the answer should be streaming" if streaming
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      holder.interrupt
      error = result.pop(timeout: 5)

      assert_kind_of Ai::Gate::Interrupted, error
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
      assert_equal :closed, stub.events.pop(timeout: 5), "the server should see the connection close"
    ensure
      thread&.join(2)
    end
end
