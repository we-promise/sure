require "test_helper"

class ProxiedHttpartyTest < ActiveSupport::TestCase
  include NetHttpCaptureHelper

  test "an HTTParty provider goes through HTTPS_PROXY when HTTP_PROXY is unset" do
    stub_request(:get, "https://api.kraken.com/0/public/Time").to_return(status: 200, body: "{}")
    calls, connection = capture_net_http_new("api.kraken.com", 443)

    with_proxy_env(https: PROXY) { Provider::Kraken.get("/0/public/Time") }

    assert_equal [ [ "api.kraken.com", 443, "proxy.internal", 8888, nil, nil ] ], calls
    assert connection.use_ssl?
  end

  test "NO_PROXY=* sends an HTTParty provider direct" do
    stub_request(:get, "https://api.kraken.com/0/public/Time").to_return(status: 200, body: "{}")
    calls, = capture_net_http_new("api.kraken.com", 443)

    with_proxy_env(https: PROXY, http: PROXY, no_proxy: "*") { Provider::Kraken.get("/0/public/Time") }

    assert_equal [ [ "api.kraken.com", 443, nil, nil, nil, nil ] ], calls
  end

  test "the proxy is resolved for each request's host, at request time" do
    stub_request(:get, "https://proxied.example.test/x").to_return(status: 200, body: "{}")
    calls, = capture_net_http_new("proxied.example.test", 443)

    with_proxy_env(https: PROXY, no_proxy: "direct.example.test") do
      Provider::Lunchflow.get("https://proxied.example.test/x")
      Provider::Lunchflow.get("https://direct.example.test/x")
    end

    assert_equal [ [ "proxied.example.test", 443, "proxy.internal", 8888, nil, nil ], [ "direct.example.test", 443, nil, nil, nil, nil ] ], calls
  end

  test "a loopback host is never proxied" do
    http = with_proxy_env(https: PROXY, http: PROXY) { connection("http://127.0.0.1:8999/api") }

    assert_not http.proxy?
    assert_not http.proxy_from_env?
  end

  test "no proxy variable leaves the connection direct" do
    http = with_proxy_env { connection("https://api.kraken.com/0/public/Time") }

    assert_not http.proxy?
    assert_not http.proxy_from_env?
  end

  test "encoded proxy credentials and an IPv6 proxy host are decoded as Net::HTTP's own lookup decodes them" do
    http = with_proxy_env(https: "http://us%3Aer:p%40ss@[::1]:8888") { connection("https://api.kraken.com") }

    assert_equal [ "::1", 8888, "us:er", "p@ss" ], [ http.proxy_address, http.proxy_port, http.proxy_user, http.proxy_pass ]
  end

  test "a proxy without a scheme is read as http://" do
    http = with_proxy_env(https: "proxy.internal:8888") { connection("https://api.kraken.com") }

    assert_equal [ "proxy.internal", 8888 ], [ http.proxy_address, http.proxy_port ]
  end

  test "SimpleFIN https requests go through the proxy and stay pinned" do
    http = with_proxy_env(https: PROXY) do
      Provider::Simplefin::PinnedConnectionAdapter.new(
        URI("https://bridge.example.test/simplefin"), connection_adapter_options: { ipaddr: "93.184.216.34" }
      ).connection
    end

    assert_equal [ "proxy.internal", 8888 ], [ http.proxy_address, http.proxy_port ]
    assert_equal "93.184.216.34", http.ipaddr
  end

  test "an explicit http_proxyaddr is left alone" do
    http = with_proxy_env(https: PROXY, http: PROXY) do
      Provider::Simplefin::PinnedConnectionAdapter.new(
        URI("http://bridge.lan/simplefin"), http_proxyaddr: nil, connection_adapter_options: { ipaddr: "192.168.1.5" }
      ).connection
    end

    assert_not http.proxy?
    assert_equal "192.168.1.5", http.ipaddr
  end

  private
    def connection(url)
      ProxiedHttparty::ConnectionAdapter.new(URI(url)).connection
    end
end
