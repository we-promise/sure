require "test_helper"

class Assistant::External::ClientTest < ActiveSupport::TestCase
  setup do
    @client = Assistant::External::Client.new(
      url: "http://localhost:18789/v1/chat/completions",
      token: "test-token",
      agent_id: "buster"
    )
  end

  test "streams text chunks from SSE response" do
    sse_body = <<~SSE
      data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}],"model":"openclaw:buster"}

      data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Your net worth"},"finish_reason":null}],"model":"openclaw:buster"}

      data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":" is $124,200."},"finish_reason":null}],"model":"openclaw:buster"}

      data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"model":"openclaw:buster"}

      data: [DONE]

    SSE

    mock_http_streaming_response(sse_body)

    chunks = []
    model = @client.chat(messages: [ { role: "user", content: "test" } ]) do |text|
      chunks << text
    end

    assert_equal [ "Your net worth", " is $124,200." ], chunks
    assert_equal "openclaw:buster", model
  end

  test "raises on non-200 response" do
    mock_http_error_response(503, "Service Unavailable")

    assert_raises(Assistant::Error) do
      @client.chat(messages: [ { role: "user", content: "test" } ]) { |_| }
    end
  end

  test "raises on connection timeout" do
    Net::HTTP.any_instance.stubs(:request).raises(Net::OpenTimeout, "connection timed out")

    assert_raises(Net::OpenTimeout) do
      @client.chat(messages: [ { role: "user", content: "test" } ]) { |_| }
    end
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
    assert_equal "openclaw:buster", body["model"]
    assert_equal true, body["stream"]
    assert_equal 3, body["messages"].size
    assert_equal "sure-family-42", body["user"]
  end

  test "sets authorization header and agent_id header" do
    sse_body = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}],\"model\":\"m\"}\n\ndata: [DONE]\n\n"
    capture = mock_http_streaming_response(sse_body)

    @client.chat(messages: [ { role: "user", content: "test" } ]) { |_| }

    assert_equal "Bearer test-token", capture[0]["Authorization"]
    assert_equal "buster", capture[0]["x-openclaw-agent-id"]
    assert_equal "agent:main:main", capture[0]["x-openclaw-session-key"]
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
      url: "https://example.com/v1/chat/completions",
      token: "test-token"
    )

    ClimateControl.modify(HTTPS_PROXY: "http://pipelock:8888") do
      client.chat(messages: [ { role: "user", content: "test" } ]) { |_| }
    end

    assert_equal "example.com", captured_args[0]
    assert_equal 443, captured_args[1]
    assert_equal "pipelock", captured_args[2]
    assert_equal 8888, captured_args[3]
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
      url: "http://openclaw.svc.cluster.local:18789/v1/chat/completions",
      token: "test-token"
    )

    ClimateControl.modify(HTTPS_PROXY: "http://pipelock:8888", NO_PROXY: "localhost,.svc.cluster.local") do
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
