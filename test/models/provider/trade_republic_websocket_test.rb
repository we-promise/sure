require "test_helper"

class Provider::TradeRepublicWebsocketTest < ActiveSupport::TestCase
  test "opens a CONNECT tunnel through the configured proxy" do
    with_proxy_server do |port, requests|
      websocket = websocket_with_proxy("http://127.0.0.1:#{port}")
      tunnel = websocket.send(:open_tunnel)
      request = requests.pop

      assert_equal "CONNECT #{Provider::TradeRepublicWebsocket::HOST}:443 HTTP/1.1\r\n", request.lines.first
      assert_includes request, "Host: #{Provider::TradeRepublicWebsocket::HOST}:443\r\n"
      assert_not_includes request, "Proxy-Authorization"
      tunnel.close
    end
  end

  test "sends proxy credentials in the CONNECT request" do
    with_proxy_server do |port, requests|
      websocket = websocket_with_proxy("http://us%40er:p%3Ass@127.0.0.1:#{port}")
      tunnel = websocket.send(:open_tunnel)

      assert_includes requests.pop, "Proxy-Authorization: Basic dXNAZXI6cDpzcw==\r\n"
      tunnel.close
    end
  end

  test "rejects a proxy response that is not a successful CONNECT" do
    with_proxy_server(response: "HTTP/1.1 403 Forbidden\r\n\r\n") do |port, _requests|
      websocket = websocket_with_proxy("http://127.0.0.1:#{port}")

      assert_raises(Provider::TradeRepublicClient::TransientProviderError) do
        websocket.send(:open_tunnel)
      end
    end
  end

  test "connects directly when no proxy is configured" do
    socket = stub
    Socket.stubs(:tcp).with(Provider::TradeRepublicWebsocket::HOST, 443, connect_timeout: 5).returns(socket)

    assert_same socket, websocket_with_proxy(nil, timeout: 5).send(:open_tunnel)
  end

  test "uses HTTP_PROXY when no HTTPS proxy is configured" do
    with_proxy_env("HTTP_PROXY" => "http://proxy.example:8888") do
      assert_equal "proxy.example", websocket.send(:proxy_uri).host
    end
  end

  test "prefers HTTPS_PROXY over HTTP_PROXY" do
    with_proxy_env("HTTPS_PROXY" => "http://secure-proxy:8443", "HTTP_PROXY" => "http://plain-proxy:8080") do
      assert_equal "secure-proxy", websocket.send(:proxy_uri).host
    end
  end

  test "honors NO_PROXY when resolving the proxy" do
    with_proxy_env("HTTP_PROXY" => "http://proxy.example:8888", "NO_PROXY" => ".traderepublic.com") do
      assert_nil websocket.send(:proxy_uri)
    end
  end

  test "rejects an unsupported proxy scheme without requiring reauthentication" do
    with_proxy_env("HTTP_PROXY" => "socks5://proxy.example:1080") do
      error = assert_raises(Provider::TradeRepublicClient::ProviderUnavailable) do
        websocket.send(:proxy_uri)
      end

      refute_kind_of Provider::TradeRepublicClient::ConfigurationError, error
    end
  end

  test "rejects an invalid proxy URI without requiring reauthentication" do
    with_proxy_env("HTTP_PROXY" => "http://[invalid") do
      error = assert_raises(Provider::TradeRepublicClient::ProviderUnavailable) do
        websocket.send(:proxy_uri)
      end

      refute_kind_of Provider::TradeRepublicClient::ConfigurationError, error
    end
  end

  private
    def websocket(timeout: 2)
      Provider::TradeRepublicWebsocket.new(headers: {}, timeout: timeout)
    end

    def websocket_with_proxy(url, timeout: 2)
      websocket(timeout: timeout).tap { |instance| instance.stubs(:proxy_uri).returns(url && URI(url)) }
    end

    def with_proxy_env(overrides)
      env = {
        "HTTP_PROXY" => nil, "http_proxy" => nil,
        "HTTPS_PROXY" => nil, "https_proxy" => nil,
        "NO_PROXY" => nil, "no_proxy" => nil
      }.merge(overrides)

      with_env_overrides(env) { yield }
    end

    def with_proxy_server(response: "HTTP/1.0 200 Connection established\r\n\r\n")
      server = TCPServer.new("127.0.0.1", 0)
      requests = Queue.new
      serving = Thread.new do
        client = server.accept
        request = +""
        while (line = client.gets)
          request << line
          break if line == "\r\n"
        end
        requests << request
        client.write(response)
        client.close
      end

      yield server.addr[1], requests
    ensure
      serving&.kill
      server&.close
    end
end
