require "test_helper"

class Assistant::External::ModelCatalogTest < ActiveSupport::TestCase
  include NetHttpCaptureHelper

  test "discovers gateway agents from the OpenAI models endpoint" do
    request = stub_request(:get, "https://agent.example.com/v1/models")
      .with(headers: { "Authorization" => "Bearer secret", "Accept" => "application/json" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { object: "list", data: [
          { id: "openclaw" },
          { id: "openclaw/default" },
          { id: "openclaw/main" },
          { id: "openclaw/research" }
        ] }.to_json
      )

    models = Assistant::External::ModelCatalog.new(
      url: "https://agent.example.com/v1/chat/completions",
      token: "secret"
    ).models

    assert_requested request
    assert_equal %w[openclaw openclaw/default openclaw/main openclaw/research], models.pluck(:id)
    assert_equal "research (openclaw/research)", models.last[:label]
  end

  test "requires a full chat completions endpoint" do
    catalog = Assistant::External::ModelCatalog.new(url: "https://agent.example.com", token: "secret")

    error = assert_raises(Assistant::External::ModelCatalog::Error) { catalog.models }
    assert_includes error.message, "endpoint must end in /chat/completions"
  end

  test "labels default agents through locale keys" do
    stub_request(:get, "https://agent.example.com/v1/models")
      .to_return(status: 200, body: { data: [ { id: "openclaw" } ] }.to_json)

    models = Assistant::External::ModelCatalog.new(url: "https://agent.example.com/v1/chat/completions", token: "secret").models

    assert_equal I18n.t("assistant.external.model_catalog.default_agent_label", id: "openclaw"), models.first[:label]
    assert_equal "Default agent (openclaw)", models.first[:label]
  end

  test "rejects invalid models response shapes" do
    [
      [ { data: [] } ],
      { data: { id: "openclaw/main" } },
      { data: [ { id: "openclaw/main" }, nil ] },
      { data: [ 1 ] },
      { object: "list" }
    ].each do |body|
      stub_request(:get, "https://agent.example.com/v1/models").to_return(status: 200, body: body.to_json)
      catalog = Assistant::External::ModelCatalog.new(url: "https://agent.example.com/v1/chat/completions", token: "secret")

      error = assert_raises(Assistant::External::ModelCatalog::Error, "expected #{body.inspect} to be rejected") { catalog.models }
      assert_equal "Agent discovery returned an invalid response.", error.message
    end
  end

  test "wraps TLS and low-level connection failures as catalog errors" do
    [ OpenSSL::SSL::SSLError, EOFError, Errno::ETIMEDOUT ].each do |error_class|
      stub_request(:get, "https://agent.example.com/v1/models").to_raise(error_class)
      catalog = Assistant::External::ModelCatalog.new(url: "https://agent.example.com/v1/chat/completions", token: "secret")

      error = assert_raises(Assistant::External::ModelCatalog::Error) { catalog.models }
      assert_includes error.message, "Agent discovery is unavailable"
    end
  end

  test "discovery goes through HTTPS_PROXY when HTTP_PROXY is unset" do
    stub_request(:get, "https://agent.example.test/v1/models").to_return(status: 200, body: { data: [ { id: "openclaw" } ] }.to_json)
    calls, connection = capture_net_http_new("agent.example.test", 443)

    with_proxy_env(https: PROXY) { catalog("https://agent.example.test/v1/chat/completions").models }

    assert_equal [ [ "agent.example.test", 443, "proxy.internal", 8888, nil, nil ] ], calls
    assert connection.use_ssl?
  end

  test "NO_PROXY=* sends discovery direct" do
    stub_request(:get, "https://agent.example.test/v1/models").to_return(status: 200, body: { data: [] }.to_json)
    calls, = capture_net_http_new("agent.example.test", 443)

    with_proxy_env(https: PROXY, http: PROXY, no_proxy: "*") { catalog("https://agent.example.test/v1/chat/completions").models }

    assert_equal [ [ "agent.example.test", 443, nil, nil, nil, nil ] ], calls
  end

  test "a loopback agent is never proxied" do
    stub_request(:get, "http://127.0.0.1:18789/v1/models").to_return(status: 200, body: { data: [] }.to_json)
    calls, connection = capture_net_http_new("127.0.0.1", 18789)

    with_proxy_env(https: PROXY, http: PROXY) { catalog("http://127.0.0.1:18789/v1/chat/completions").models }

    assert_equal [ [ "127.0.0.1", 18789, nil, nil, nil, nil ] ], calls
    assert_not connection.use_ssl?
  end

  test "an unreadable proxy fails discovery with ModelCatalog::Error" do
    stub_request(:get, "https://agent.example.test/v1/models").to_return(status: 200, body: { data: [] }.to_json)

    error = with_proxy_env(https: "http://bad host:8888") do
      assert_raises(Assistant::External::ModelCatalog::Error) { catalog("https://agent.example.test/v1/chat/completions").models }
    end

    assert_equal "Agent discovery is unavailable: The outbound proxy URL cannot be read", error.message
    refute_includes error.message, "bad host"
    assert_not_requested :get, "https://agent.example.test/v1/models"
  end

  private
    def catalog(url)
      Assistant::External::ModelCatalog.new(url:, token: "secret")
    end
end
