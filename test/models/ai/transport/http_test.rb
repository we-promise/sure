require "test_helper"

class Ai::Transport::HttpTest < ActiveSupport::TestCase
  Http = Ai::Transport::Http
  PROXY = "http://proxy.internal:8888"

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

    with_env_overrides("HTTPS_PROXY" => PROXY, "NO_PROXY" => nil, "no_proxy" => nil) do
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
