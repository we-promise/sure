require "test_helper"

class HttpProxyTest < ActiveSupport::TestCase
  test "returns nil when no proxy is configured" do
    with_proxy_env do
      assert_nil HttpProxy.resolve(scheme: "https", host: "api.traderepublic.com")
    end
  end

  test "uses the proxy variable matching the request scheme" do
    with_proxy_env(
      "HTTPS_PROXY" => "http://secure-proxy:8443",
      "HTTP_PROXY" => "http://plain-proxy:8080"
    ) do
      assert_equal "secure-proxy", HttpProxy.resolve(scheme: "https", host: "example.com").host
      assert_equal "plain-proxy", HttpProxy.resolve(scheme: "http", host: "example.com").host
    end
  end

  test "falls back to HTTP_PROXY for HTTPS requests when enabled" do
    with_proxy_env("HTTP_PROXY" => "http://plain-proxy:8080") do
      proxy = HttpProxy.resolve(scheme: "https", host: "example.com", fallback: true)

      assert_equal "plain-proxy", proxy.host
    end
  end

  test "does not fall back to HTTP_PROXY by default" do
    with_proxy_env("HTTP_PROXY" => "http://plain-proxy:8080") do
      assert_nil HttpProxy.resolve(scheme: "https", host: "example.com")
    end
  end

  test "prefers HTTPS_PROXY over HTTP_PROXY when falling back" do
    with_proxy_env(
      "HTTPS_PROXY" => "http://secure-proxy:8443",
      "HTTP_PROXY" => "http://plain-proxy:8080"
    ) do
      proxy = HttpProxy.resolve(scheme: "https", host: "example.com", fallback: true)

      assert_equal "secure-proxy", proxy.host
    end
  end

  test "accepts lowercase proxy environment variables" do
    with_proxy_env("https_proxy" => "http://lower-proxy:8080") do
      proxy = HttpProxy.resolve(scheme: "https", host: "example.com")

      assert_equal "lower-proxy", proxy.host
    end
  end

  test "preserves proxy credentials" do
    with_proxy_env("HTTPS_PROXY" => "http://user:pass@proxy.example:8443") do
      proxy = HttpProxy.resolve(scheme: "https", host: "example.com")

      assert_equal "user", proxy.user
      assert_equal "pass", proxy.password
    end
  end

  test "bypasses hosts matched by NO_PROXY" do
    with_proxy_env(
      "HTTPS_PROXY" => "http://proxy.example:8443",
      "NO_PROXY" => ".example.com, other.test"
    ) do
      assert_nil HttpProxy.resolve(scheme: "https", host: "api.example.com")
      assert_nil HttpProxy.resolve(scheme: "https", host: "other.test")
      assert_equal "proxy.example", HttpProxy.resolve(scheme: "https", host: "example.org").host
    end
  end

  test "bypasses every host with a wildcard NO_PROXY" do
    with_proxy_env(
      "HTTPS_PROXY" => "http://proxy.example:8443",
      "NO_PROXY" => "*"
    ) do
      assert_nil HttpProxy.resolve(scheme: "https", host: "api.traderepublic.com")
    end
  end

  test "falls back to lowercase no_proxy when NO_PROXY is empty" do
    with_proxy_env(
      "HTTPS_PROXY" => "http://proxy.example:8443",
      "NO_PROXY" => "",
      "no_proxy" => ".example.com"
    ) do
      assert_nil HttpProxy.resolve(scheme: "https", host: "api.example.com")
    end
  end

  test "raises for an invalid proxy URL" do
    with_proxy_env("HTTPS_PROXY" => "http://[invalid") do
      assert_raises(URI::InvalidURIError) do
        HttpProxy.resolve(scheme: "https", host: "example.com")
      end
    end
  end

  private
    def with_proxy_env(overrides = {})
      env = {
        "HTTP_PROXY" => nil, "http_proxy" => nil,
        "HTTPS_PROXY" => nil, "https_proxy" => nil,
        "NO_PROXY" => nil, "no_proxy" => nil
      }.merge(overrides)

      with_env_overrides(env) { yield }
    end
end
