require "test_helper"

class Ai::Transport::HttpTest < ActiveSupport::TestCase
  Http = Ai::Transport::Http
  PROXY = "http://proxy.internal:8888"

  test "HTTPS_PROXY is used, then HTTP_PROXY, whatever the target's scheme" do
    assert_equal PROXY, Http.proxy_for("https://api.anthropic.com", env: { "HTTPS_PROXY" => PROXY })
    assert_equal PROXY, Http.proxy_for("http://llm.lan:8080", env: { "HTTPS_PROXY" => PROXY })
    assert_equal PROXY, Http.proxy_for("https://api.openai.com", env: { "HTTP_PROXY" => PROXY })
    assert_equal "http://a:1", Http.proxy_for("https://x.test", env: { "HTTPS_PROXY" => "http://a:1", "HTTP_PROXY" => "http://b:2" })
    assert_nil Http.proxy_for("https://api.openai.com", env: {})
  end

  test "loopback is never proxied, as Ruby's own lookup doesn't" do
    env = { "HTTPS_PROXY" => PROXY }

    %w[http://127.0.0.1:8080 http://127.1.2.3:11434 http://localhost:1234 http://[::1]:8080].each do |url|
      assert_nil Http.proxy_for(url, env:), url
    end
  end

  test "NO_PROXY matches the host as written, with CIDR blocks" do
    env = { "HTTPS_PROXY" => PROXY, "NO_PROXY" => "llm.lan,10.0.0.0/8" }

    assert_nil Http.proxy_for("http://llm.lan:8080", env:)
    assert_nil Http.proxy_for("http://10.72.200.61:8180", env:)
    assert_equal PROXY, Http.proxy_for("http://other.lan:8080", env:)
  end

  test "NO_PROXY=* sends every host direct" do
    assert_nil Http.proxy_for("https://api.openai.com", env: { "HTTPS_PROXY" => PROXY, "NO_PROXY" => "*" })
    assert_nil Http.proxy_for("http://llm.lan:8080", env: { "HTTP_PROXY" => PROXY, "no_proxy" => " * " })
  end

  test "the models list goes to the same server as the chat calls it checks" do
    full = Ai::Config::Endpoint.new(name: "gw", protocol: :compatible, base_url: "https://gw.example.test/v1/chat/completions", api_key: "k")
    openrouter = Ai::Config::Endpoint.new(name: "or", protocol: :compatible, preset: :openrouter, api_key: "or-key")
    stub_request(:get, "https://gw.example.test/v1/models").to_return(status: 200, body: { data: [] }.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:get, "https://openrouter.ai/api/v1/models").to_return(status: 200, body: { data: [] }.to_json, headers: { "Content-Type" => "application/json" })

    Http.openai_client(full).models.list
    Http.openai_client(openrouter).models.list

    assert_requested :get, "https://gw.example.test/v1/models"
    assert_requested :get, "https://openrouter.ai/api/v1/models", headers: { "Authorization" => "Bearer or-key" }
    assert_not_requested :get, %r{api\.openai\.com}
  end

  test "net_http_proxy returns a URI for Net::HTTP" do
    uri = Http.net_http_proxy("https://agent.example.test", env: { "HTTPS_PROXY" => "http://user:pw@proxy.internal:8888" })

    assert_equal [ "proxy.internal", 8888, "user", "pw" ], [ uri.host, uri.port, uri.user, uri.password ]
  end

  test "compatible base URLs follow ruby-openai's rule, so today's URLs keep working" do
    {
      nil => "https://api.openai.com/v1",
      "http://llm:8080" => "http://llm:8080/v1",
      "http://llm:8080/" => "http://llm:8080/v1",
      "http://ollama:11434/v1/" => "http://ollama:11434/v1",
      "https://generativelanguage.googleapis.com/v1beta/openai/" => "https://generativelanguage.googleapis.com/v1beta/openai",
      "https://api.cloudflare.com/client/v4/accounts/a/ai/v1" => "https://api.cloudflare.com/client/v4/accounts/a/ai/v1",
      "http://agent:18789/v1/chat/completions" => "http://agent:18789/v1"
    }.each do |given, expected|
      assert_equal expected, Http.compatible_base(given), given.inspect
    end
  end

  test "headers leave out per-chat {session_id} values" do
    endpoint = ai_endpoint(extra_headers: { "X-Team" => "home", "X-Session" => "sure-{session_id}" })

    assert_equal({ "X-Team" => "home" }, Http.headers(endpoint))
  end

  test "the ruby-openai client gets the endpoint's settings and the resolved proxy" do
    endpoint = ai_endpoint(base_url: "https://llm.example.test/v1", extra_headers: { "X-Team" => "home" }, timeout_seconds: 7)

    with_env_overrides("HTTPS_PROXY" => PROXY) do
      client = Http.openai_client(endpoint)
      connection = Faraday.new.tap { client.faraday_middleware.call(_1) }

      assert_equal 7, client.request_timeout
      assert_equal({ "X-Team" => "home" }, client.extra_headers)
      assert_equal URI(PROXY), connection.proxy.uri
    end
  end

  test "a direct client stops Faraday's own proxy lookup" do
    endpoint = ai_endpoint(base_url: "http://127.0.0.1:8080/v1")

    with_env_overrides("HTTP_PROXY" => PROXY) do
      connection = Faraday.new.tap { Http.openai_client(endpoint).faraday_middleware.call(_1) }

      assert_nil connection.proxy
    end
  end
end
