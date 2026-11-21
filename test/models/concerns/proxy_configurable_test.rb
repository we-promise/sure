require "test_helper"

class ProxyConfigurableTest < ActiveSupport::TestCase
  PROXY = "http://proxy.internal:8888"

  test "HTTPS_PROXY is used, then HTTP_PROXY, whatever the target's scheme" do
    assert_equal PROXY, ProxyConfigurable.url_for("https://api.anthropic.com", env: { "HTTPS_PROXY" => PROXY })
    assert_equal PROXY, ProxyConfigurable.url_for("http://llm.lan:8080", env: { "HTTPS_PROXY" => PROXY })
    assert_equal PROXY, ProxyConfigurable.url_for("https://api.openai.com", env: { "HTTP_PROXY" => PROXY })
    assert_equal "http://a:1", ProxyConfigurable.url_for("https://x.test", env: { "HTTPS_PROXY" => "http://a:1", "HTTP_PROXY" => "http://b:2" })
    assert_nil ProxyConfigurable.url_for("https://api.openai.com", env: {})
  end

  test "loopback is never proxied, as Ruby's own lookup doesn't" do
    env = { "HTTPS_PROXY" => PROXY }

    %w[http://127.0.0.1:8080 http://127.1.2.3:11434 http://localhost:1234 http://[::1]:8080].each do |url|
      assert_nil ProxyConfigurable.url_for(url, env:), url
    end
  end

  test "NO_PROXY matches the host as written, with CIDR blocks" do
    env = { "HTTPS_PROXY" => PROXY, "NO_PROXY" => "llm.lan,10.0.0.0/8" }

    assert_nil ProxyConfigurable.url_for("http://llm.lan:8080", env:)
    assert_nil ProxyConfigurable.url_for("http://10.72.200.61:8180", env:)
    assert_equal PROXY, ProxyConfigurable.url_for("http://other.lan:8080", env:)
  end

  test "a host named by DNS goes direct when its address is in a NO_PROXY CIDR block" do
    IPSocket.stubs(:getaddress).with("llm.internal").returns("10.72.200.61")
    env = { "HTTPS_PROXY" => PROXY, "NO_PROXY" => "10.0.0.0/8" }

    assert_nil ProxyConfigurable.url_for("http://llm.internal:8180", env:)
    IPSocket.stubs(:getaddress).with("api.openai.com").returns("162.159.140.245")
    assert_equal PROXY, ProxyConfigurable.url_for("https://api.openai.com", env:)
  end

  test "a name is never resolved when NO_PROXY lists only names" do
    IPSocket.expects(:getaddress).never

    assert_nil ProxyConfigurable.url_for("http://llm.lan:8080", env: { "HTTPS_PROXY" => PROXY, "NO_PROXY" => "llm.lan" })
  end

  test "a NO_PROXY entry with a leading dot covers the domain itself and its subdomains" do
    env = { "HTTPS_PROXY" => PROXY, "NO_PROXY" => "other.test, .agents.example.com" }

    assert_nil ProxyConfigurable.url_for("https://agents.example.com", env:)
    assert_nil ProxyConfigurable.url_for("https://eu.agents.example.com", env:)
    assert_equal PROXY, ProxyConfigurable.url_for("https://badagents.example.com", env:)
  end

  test "NO_PROXY=* sends every host direct" do
    assert_nil ProxyConfigurable.url_for("https://api.openai.com", env: { "HTTPS_PROXY" => PROXY, "NO_PROXY" => "*" })
    assert_nil ProxyConfigurable.url_for("http://llm.lan:8080", env: { "HTTP_PROXY" => PROXY, "no_proxy" => " * " })
  end

  test "net_http_args gives Net::HTTP's four proxy arguments, or all nil to go direct" do
    env = { "HTTPS_PROXY" => "http://user:pw@proxy.internal:8888" }

    assert_equal [ "proxy.internal", 8888, "user", "pw" ], ProxyConfigurable.net_http_args("https://agent.example.test", env:)
    assert_equal [ nil, nil, nil, nil ], ProxyConfigurable.net_http_args("https://agent.example.test", env: {})
    assert_equal [ nil, nil, nil, nil ], ProxyConfigurable.net_http_args("http://127.0.0.1:8080", env:)
  end

  test "net_http_args decodes the credentials and unbrackets an IPv6 proxy, as Net::HTTP's own lookup does" do
    env = { "HTTPS_PROXY" => "http://us%3Aer:p%40ss%2Fw@[::1]:8888" }

    assert_equal [ "::1", 8888, "us:er", "p@ss/w" ], ProxyConfigurable.net_http_args("https://agent.example.test", env:)
  end

  test "a proxy without a scheme is read as http://" do
    env = { "HTTPS_PROXY" => "proxy.internal:8888" }

    assert_equal "http://proxy.internal:8888", ProxyConfigurable.url_for("https://agent.example.test", env:)
    assert_equal [ "proxy.internal", 8888, nil, nil ], ProxyConfigurable.net_http_args("https://agent.example.test", env:)
  end

  test "a proxy that cannot be read raises instead of going direct" do
    assert_raises(ProxyConfigurable::InvalidProxyError) do
      ProxyConfigurable.url_for("https://agent.example.test", env: { "HTTPS_PROXY" => "http://bad host:8888" })
    end
    error = assert_raises(ProxyConfigurable::InvalidProxyError) do
      ProxyConfigurable.net_http_args("https://agent.example.test", env: { "HTTPS_PROXY" => "http://user:secret@" })
    end
    assert_not_includes error.message, "secret"
  end

  test "an extending class gains only the two prefixed methods" do
    client = Class.new do
      extend ProxyConfigurable

      def self.parse(value) = "own #{value}"
    end

    assert_equal "own x", client.parse("x")
    assert_equal PROXY, client.proxy_url_for("https://agent.example.test", env: { "HTTPS_PROXY" => PROXY })
    assert_equal [ "proxy.internal", 8888, nil, nil ], client.net_http_proxy_args("https://agent.example.test", env: { "HTTPS_PROXY" => PROXY })
    %i[url_for net_http_args address ip? loopback?].each { assert_not client.respond_to?(_1, true), _1 }
  end
end
