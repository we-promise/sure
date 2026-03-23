require "test_helper"

class Assistant::External::ClientTest < ActiveSupport::TestCase
  setup do
    @client = Assistant::External::Client.new(
      url: "http://localhost:18789/v1/chat",
      token: "test-token",
      agent_id: "test-agent"
    )
  end

  test "streams text chunks from SSE response" do
    sse_body = <<~SSE
      data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}],"model":"test-agent"}

      data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Your net worth"},"finish_reason":null}],"model":"test-agent"}

      data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":" is $124,200."},"finish_reason":null}],"model":"test-agent"}

      data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"model":"test-agent"}

      data: [DONE]

    SSE

    mock_http_streaming_response(sse_body)

    chunks = []
    model = @client.chat(messages: [ { role: "user", content: "test" } ]) do |text|
      chunks << text
    end

    assert_equal [ "Your net worth", " is $124,200." ], chunks
    assert_equal "test-agent", model
  end

  test "raises on non-200 response" do
    mock_http_error_response(503, "Service Unavailable")

    assert_raises(Assistant::Error) do
      @client.chat(messages: [ { role: "user", content: "test" } ]) { |_| }
    end
  end

  test "retries transient errors then raises Assistant::Error" do
    Net::HTTP.any_instance.stubs(:request).raises(Net::OpenTimeout, "connection timed out")

    error = assert_raises(Assistant::Error) do
      @client.chat(messages: [ { role: "user", content: "test" } ]) { |_| }
    end

    assert_match(/temporarily unavailable/, error.message)
  end

  test "does not retry after streaming has started" do
    call_count = 0

    # Custom response that yields one chunk then raises mid-stream
    mock_response = Object.new
    mock_response.define_singleton_method(:is_a?) { |klass| klass == Net::HTTPSuccess }
    mock_response.define_singleton_method(:read_body) do |&blk|
      blk.call("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}],\"model\":\"m\"}\n\n")
      raise Errno::ECONNRESET, "connection reset mid-stream"
    end

    mock_http = stub("http")
    mock_http.stubs(:use_ssl=)
    mock_http.stubs(:open_timeout=)
    mock_http.stubs(:read_timeout=)
    mock_http.define_singleton_method(:request) do |_req, &blk|
      call_count += 1
      blk.call(mock_response)
    end

    Net::HTTP.stubs(:new).returns(mock_http)

    chunks = []
    error = assert_raises(Assistant::Error) do
      @client.chat(messages: [ { role: "user", content: "test" } ]) { |t| chunks << t }
    end

    assert_equal 1, call_count, "Should not retry after streaming started"
    assert_equal [ "partial" ], chunks
    assert_match(/connection was interrupted/, error.message)
  end

  test "builds correct request payload" do
    sse_body = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}],\"model\":\"m\"}\n\ndata: [DONE]\n\n"
    capture = mock_http_streaming_response(sse_body)

    @client.chat(
      messages: [
        { role: "user", content: "Hello" },
        { role: "assistant", content: "Hi there" },
        { role: "user", content: "What is my balance?" }
      ],
      user: "sure-family-42"
    ) { |_| }

    body = JSON.parse(capture[0].body)
    assert_equal "test-agent", body["model"]
    assert_equal true, body["stream"]
    assert_equal 3, body["messages"].size
    assert_equal "sure-family-42", body["user"]
  end

  test "sets authorization header and agent_id header" do
    sse_body = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}],\"model\":\"m\"}\n\ndata: [DONE]\n\n"
    capture = mock_http_streaming_response(sse_body)

    @client.chat(messages: [ { role: "user", content: "test" } ]) { |_| }

    assert_equal "Bearer test-token", capture[0]["Authorization"]
    assert_equal "test-agent", capture[0]["X-Agent-Id"]
    assert_equal "agent:main:main", capture[0]["X-Session-Key"]
    assert_equal "text/event-stream", capture[0]["Accept"]
    assert_equal "application/json", capture[0]["Content-Type"]
  end

  test "omits user field when not provided" do
    sse_body = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}],\"model\":\"m\"}\n\ndata: [DONE]\n\n"
    capture = mock_http_streaming_response(sse_body)

    @client.chat(messages: [ { role: "user", content: "test" } ]) { |_| }

    body = JSON.parse(capture[0].body)
    assert_not body.key?("user")
  end

  test "handles malformed JSON in SSE data gracefully" do
    sse_body = "data: {not valid json}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"OK\"}}],\"model\":\"m\"}\n\ndata: [DONE]\n\n"
    mock_http_streaming_response(sse_body)

    chunks = []
    @client.chat(messages: [ { role: "user", content: "test" } ]) { |t| chunks << t }

    assert_equal [ "OK" ], chunks
  end

  test "handles SSE data: field without space after colon (spec-compliant)" do
    sse_body = "data:{\"choices\":[{\"delta\":{\"content\":\"no space\"}}],\"model\":\"m\"}\n\ndata:[DONE]\n\n"
    mock_http_streaming_response(sse_body)

    chunks = []
    @client.chat(messages: [ { role: "user", content: "test" } ]) { |t| chunks << t }

    assert_equal [ "no space" ], chunks
  end

  test "handles chunked SSE data split across read_body calls" do
    chunk1 = "data: {\"choices\":[{\"delta\":{\"content\":\"Hel"
    chunk2 = "lo\"}}],\"model\":\"m\"}\n\ndata: [DONE]\n\n"

    mock_http_streaming_response_chunked([ chunk1, chunk2 ])

    chunks = []
    @client.chat(messages: [ { role: "user", content: "test" } ]) { |t| chunks << t }

    assert_equal [ "Hello" ], chunks
  end

  test "routes through HTTPS_PROXY when set" do
    sse_body = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}],\"model\":\"m\"}\n\ndata: [DONE]\n\n"

    mock_response = stub("response")
    mock_response.stubs(:code).returns("200")
    mock_response.stubs(:is_a?).with(Net::HTTPSuccess).returns(true)
    mock_response.stubs(:read_body).yields(sse_body)

    mock_http = stub("http")
    mock_http.stubs(:use_ssl=)
    mock_http.stubs(:open_timeout=)
    mock_http.stubs(:read_timeout=)
    mock_http.stubs(:request).yields(mock_response)

    captured_args = nil
    Net::HTTP.stubs(:new).with do |*args|
      captured_args = args
      true
    end.returns(mock_http)

    client = Assistant::External::Client.new(
      url: "https://example.com/v1/chat",
      token: "test-token"
    )

    ClimateControl.modify(HTTPS_PROXY: "http://proxyuser:proxypass@proxy:8888") do
      client.chat(messages: [ { role: "user", content: "test" } ]) { |_| }
    end

    assert_equal "example.com", captured_args[0]
    assert_equal 443, captured_args[1]
    assert_equal "proxy", captured_args[2]
    assert_equal 8888, captured_args[3]
    assert_equal "proxyuser", captured_args[4]
    assert_equal "proxypass", captured_args[5]
  end

  # -- WebSocket transport tests ------------------------------------------

  test "streams text chunks from WebSocket response" do
    ws_client = Assistant::External::Client.new(
      url: "wss://localhost:18789/v1/chat",
      token: "test-token",
      agent_id: "test-agent"
    )

    frames = [
      '{"id":"1","choices":[{"delta":{"role":"assistant"}}],"model":"test-agent"}',
      '{"id":"1","choices":[{"delta":{"content":"Hello"}}],"model":"test-agent"}',
      '{"id":"1","choices":[{"delta":{"content":" world"}}],"model":"test-agent"}',
      "[DONE]"
    ]

    mock_ws_transport(ws_client, frames)

    chunks = []
    model = ws_client.chat(messages: [ { role: "user", content: "test" } ]) { |t| chunks << t }

    assert_equal [ "Hello", " world" ], chunks
    assert_equal "test-agent", model
  end

  test "WebSocket handles SSE-formatted frames (data: prefix)" do
    ws_client = Assistant::External::Client.new(
      url: "wss://localhost:18789/v1/chat",
      token: "test-token",
      agent_id: "test-agent"
    )

    frames = [
      'data: {"id":"1","choices":[{"delta":{"content":"prefixed"}}],"model":"m"}',
      "data: [DONE]"
    ]

    mock_ws_transport(ws_client, frames)

    chunks = []
    ws_client.chat(messages: [ { role: "user", content: "test" } ]) { |t| chunks << t }

    assert_equal [ "prefixed" ], chunks
  end

  test "WebSocket retries transient errors then raises" do
    ws_client = Assistant::External::Client.new(
      url: "wss://localhost:18789/v1/chat",
      token: "test-token",
      agent_id: "test-agent"
    )

    ws_client.stubs(:open_ws_socket).raises(Errno::ECONNREFUSED, "connection refused")

    error = assert_raises(Assistant::Error) do
      ws_client.chat(messages: [ { role: "user", content: "test" } ]) { |_| }
    end

    assert_match(/temporarily unavailable/, error.message)
  end

  test "WebSocket does not retry after streaming started" do
    ws_client = Assistant::External::Client.new(
      url: "wss://localhost:18789/v1/chat",
      token: "test-token",
      agent_id: "test-agent"
    )

    call_count = 0
    ws_client.stubs(:open_ws_socket).with do
      call_count += 1
      true
    end.returns(StringIO.new)

    mock_driver = mock("driver")
    open_callback = nil
    message_callback = nil

    mock_driver.stubs(:set_header)
    mock_driver.stubs(:on).with(:open).with { |event, &blk| open_callback = blk; true }
    mock_driver.stubs(:on).with(:message).with { |event, &blk| message_callback = blk; true }
    mock_driver.stubs(:on).with(:close)
    mock_driver.stubs(:on).with(:error)
    mock_driver.stubs(:text)
    mock_driver.stubs(:close)
    mock_driver.stubs(:start) do
      open_callback&.call(nil)
    end

    WebSocket::Driver::Client.stubs(:new).returns(mock_driver)

    # Simulate: first IO.select returns data, readpartial triggers message then error
    first_read = true
    IO.stubs(:select).returns([ [ StringIO.new ] ])
    mock_socket = StringIO.new
    ws_client.stubs(:open_ws_socket).returns(mock_socket)
    mock_socket.stubs(:close)
    mock_socket.define_singleton_method(:readpartial) do |_|
      if first_read
        first_read = false
        msg_event = OpenStruct.new(data: '{"choices":[{"delta":{"content":"partial"}}],"model":"m"}')
        message_callback&.call(msg_event)
        raise Errno::ECONNRESET, "connection reset"
      end
    end

    mock_driver.stubs(:parse)

    chunks = []
    error = assert_raises(Assistant::Error) do
      ws_client.chat(messages: [ { role: "user", content: "test" } ]) { |t| chunks << t }
    end

    assert_equal [ "partial" ], chunks
    assert_match(/connection was interrupted/, error.message)
  end

  test "raises for unsupported URL scheme" do
    client = Assistant::External::Client.new(
      url: "ftp://localhost/v1/chat",
      token: "test-token"
    )

    error = assert_raises(Assistant::Error) do
      client.chat(messages: [ { role: "user", content: "test" } ]) { |_| }
    end

    assert_match(/Unsupported URL scheme/, error.message)
  end

  test "auto-detects ws:// scheme for WebSocket transport" do
    ws_client = Assistant::External::Client.new(
      url: "ws://localhost:18789/v1/chat",
      token: "test-token",
      agent_id: "test-agent"
    )

    frames = [
      '{"id":"1","choices":[{"delta":{"content":"ws works"}}],"model":"m"}',
      "[DONE]"
    ]

    mock_ws_transport(ws_client, frames)

    chunks = []
    ws_client.chat(messages: [ { role: "user", content: "test" } ]) { |t| chunks << t }

    assert_equal [ "ws works" ], chunks
  end

  test "WebSocket sends correct payload and headers" do
    ws_client = Assistant::External::Client.new(
      url: "wss://localhost:18789/v1/chat",
      token: "test-token",
      agent_id: "test-agent",
      session_key: "custom:session"
    )

    frames = [
      '{"id":"1","choices":[{"delta":{"content":"hi"}}],"model":"m"}',
      "[DONE]"
    ]
    mock_ws_transport(ws_client, frames)

    ws_client.chat(
      messages: [ { role: "user", content: "Hello" } ],
      user: "sure-family-42"
    ) { |_| }

    headers = ws_client._ws_captured_headers
    payload = ws_client._ws_captured_payload

    assert_equal "Bearer test-token", headers["Authorization"]
    assert_equal "test-agent", headers["X-Agent-Id"]
    assert_equal "custom:session", headers["X-Session-Key"]
    assert_equal "test-agent", payload["model"]
    assert_equal true, payload["stream"]
    assert_equal "sure-family-42", payload["user"]
    assert_equal 1, payload["messages"].size
  end

  test "skips proxy for hosts in NO_PROXY" do
    sse_body = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}],\"model\":\"m\"}\n\ndata: [DONE]\n\n"

    mock_response = stub("response")
    mock_response.stubs(:code).returns("200")
    mock_response.stubs(:is_a?).with(Net::HTTPSuccess).returns(true)
    mock_response.stubs(:read_body).yields(sse_body)

    mock_http = stub("http")
    mock_http.stubs(:use_ssl=)
    mock_http.stubs(:open_timeout=)
    mock_http.stubs(:read_timeout=)
    mock_http.stubs(:request).yields(mock_response)

    captured_args = nil
    Net::HTTP.stubs(:new).with do |*args|
      captured_args = args
      true
    end.returns(mock_http)

    client = Assistant::External::Client.new(
      url: "http://agent.internal.example.com:18789/v1/chat",
      token: "test-token"
    )

    ClimateControl.modify(HTTP_PROXY: "http://proxy:8888", NO_PROXY: "localhost,.example.com") do
      client.chat(messages: [ { role: "user", content: "test" } ]) { |_| }
    end

    # Should NOT pass proxy args — only host and port
    assert_equal 2, captured_args.length
  end

  private

    def mock_http_streaming_response(sse_body)
      capture = []
      mock_response = stub("response")
      mock_response.stubs(:code).returns("200")
      mock_response.stubs(:is_a?).with(Net::HTTPSuccess).returns(true)
      mock_response.stubs(:read_body).yields(sse_body)

      mock_http = stub("http")
      mock_http.stubs(:use_ssl=)
      mock_http.stubs(:open_timeout=)
      mock_http.stubs(:read_timeout=)
      mock_http.stubs(:request).with do |req|
        capture[0] = req
        true
      end.yields(mock_response)

      Net::HTTP.stubs(:new).returns(mock_http)
      capture
    end

    def mock_http_streaming_response_chunked(chunks)
      mock_response = stub("response")
      mock_response.stubs(:code).returns("200")
      mock_response.stubs(:is_a?).with(Net::HTTPSuccess).returns(true)
      mock_response.stubs(:read_body).multiple_yields(*chunks.map { |c| [ c ] })

      mock_http = stub("http")
      mock_http.stubs(:use_ssl=)
      mock_http.stubs(:open_timeout=)
      mock_http.stubs(:read_timeout=)
      mock_http.stubs(:request).yields(mock_response)

      Net::HTTP.stubs(:new).returns(mock_http)
    end

    def mock_ws_transport(ws_client, frames)
      mock_socket = StringIO.new
      mock_socket.stubs(:close)
      ws_client.stubs(:open_ws_socket).returns(mock_socket)

      captured_headers = {}
      captured_payload = nil

      mock_driver = Object.new
      callbacks = {}

      mock_driver.define_singleton_method(:set_header) { |k, v| captured_headers[k] = v }
      mock_driver.define_singleton_method(:on) { |event, &blk| callbacks[event] = blk }
      mock_driver.define_singleton_method(:text) { |json| captured_payload = JSON.parse(json) }
      mock_driver.define_singleton_method(:close) { callbacks[:close]&.call(nil) }
      mock_driver.define_singleton_method(:start) { callbacks[:open]&.call(nil) }
      mock_driver.define_singleton_method(:parse) do |_data|
        frame = frames.shift
        return unless frame
        callbacks[:message]&.call(OpenStruct.new(data: frame))
      end

      WebSocket::Driver::Client.stubs(:new).returns(mock_driver)

      read_count = 0
      IO.stubs(:select).returns([ [ mock_socket ] ])
      mock_socket.define_singleton_method(:readpartial) do |_|
        read_count += 1
        raise EOFError, "done" if read_count > frames.size + 5 # safety
        "fake"
      end

      # Store captures for assertions
      ws_client.define_singleton_method(:_ws_captured_headers) { captured_headers }
      ws_client.define_singleton_method(:_ws_captured_payload) { captured_payload }
    end

    def mock_http_error_response(code, message)
      mock_response = stub("response")
      mock_response.stubs(:code).returns(code.to_s)
      mock_response.stubs(:is_a?).with(Net::HTTPSuccess).returns(false)
      mock_response.stubs(:body).returns(message)

      mock_http = stub("http")
      mock_http.stubs(:use_ssl=)
      mock_http.stubs(:open_timeout=)
      mock_http.stubs(:read_timeout=)
      mock_http.stubs(:request).yields(mock_response)

      Net::HTTP.stubs(:new).returns(mock_http)
    end
end
