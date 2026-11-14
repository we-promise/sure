require "test_helper"

class Eval::ProviderFactoryTest < ActiveSupport::TestCase
  test "a run on the install's own server measures it as production calls it" do
    endpoint = ai_endpoint(name: "openai_compatible", base_url: "https://gateway.example.test/v1",
                           extra_headers: { "X-Gateway-Key" => "tenant-1" }, responses_api: true)
    installed = ai_model(endpoint:, name: "qwen3", max_output_tokens: 700, batch_size: 7, context_window: 9000)

    client = Ai::Config.with(AiTestHelper.build_ai_config([ installed ], {})) { Eval::ProviderFactory.build(provider: "openai", model: "qwen3") }
    model = client.ai_config(:categorize).models.sole

    assert_equal({ "X-Gateway-Key" => "tenant-1" }, model.endpoint.extra_headers)
    assert model.endpoint.responses_api
    assert_equal [ 700, 7, 9000 ], [ model.max_output_tokens, model.batch_size, model.context_window ]
  end

  test "a run with its own token keeps the configured gateway when the install has no token" do
    with_env_overrides("OPENAI_URI_BASE" => "http://gateway.lan:4000/v1", "OPENAI_ACCESS_TOKEN" => nil) do
      client = Ai::Config.with(Ai::Config.new) do
        Eval::ProviderFactory.build(provider: "openai", model: "m", config: { access_token: "run-token" })
      end

      endpoint = client.ai_config(:categorize).endpoints.sole
      assert_equal [ "http://gateway.lan:4000/v1", "run-token" ], [ endpoint.base_url, endpoint.api_key ]
    end
  end

  test "a run URL that differs from the install's only by a trailing slash is the install's server" do
    endpoint = ai_endpoint(name: "openai_compatible", base_url: "https://gateway.example.test/v1", extra_headers: { "X-Gateway-Key" => "tenant-1" })

    client = Ai::Config.with(AiTestHelper.build_ai_config([ ai_model(endpoint:, name: "qwen3") ], {})) do
      Eval::ProviderFactory.build(provider: "openai", model: "qwen3", config: { uri_base: "https://gateway.example.test/v1/", access_token: "t" })
    end

    assert_equal({ "X-Gateway-Key" => "tenant-1" }, client.ai_config(:categorize).endpoints.sole.extra_headers)
  end

  test "a run with its own token on the configured gateway keeps the gateway's static headers" do
    with_env_overrides("OPENAI_URI_BASE" => "http://gateway.lan:4000/v1", "OPENAI_ACCESS_TOKEN" => nil,
                       "OPENAI_EXTRA_HEADERS" => { "X-Tenant" => "home", "X-Session" => "{session_id}" }.to_json) do
      client = Ai::Config.with(Ai::Config.new) do
        Eval::ProviderFactory.build(provider: "openai", model: "m", config: { access_token: "run-token" })
      end

      assert_equal({ "X-Tenant" => "home" }, client.ai_config(:categorize).endpoints.sole.extra_headers)
    end
  end

  test "a run on a custom gateway honours OPENAI_SUPPORTS_RESPONSES_ENDPOINT, as production does" do
    with_env_overrides("OPENAI_URI_BASE" => "https://gateway.example.test/v1", "OPENAI_ACCESS_TOKEN" => nil,
                       "OPENAI_SUPPORTS_RESPONSES_ENDPOINT" => "true") do
      client = Ai::Config.with(Ai::Config.new) do
        Eval::ProviderFactory.build(provider: "openai", model: "m", config: { access_token: "run-token" })
      end

      assert client.ai_config(:categorize).endpoints.sole.responses_api
    end
  end

  test "a run with its own token on the configured gateway keeps the operator's timeout and JSON mode" do
    with_env_overrides("OPENAI_URI_BASE" => "http://gateway.lan:4000/v1", "OPENAI_ACCESS_TOKEN" => nil,
                       "OPENAI_REQUEST_TIMEOUT" => "300", "LLM_JSON_MODE" => "strict") do
      client = Ai::Config.with(Ai::Config.new) do
        Eval::ProviderFactory.build(provider: "openai", model: "m", config: { access_token: "run-token" })
      end

      endpoint = client.ai_config(:categorize).endpoints.sole
      assert_equal [ 300, :strict ], [ endpoint.timeout_seconds, endpoint.json_mode ]
    end
  end

  test "a run on its own server gets a plain endpoint" do
    installed = ai_model(endpoint: ai_endpoint(name: "openai_compatible", extra_headers: { "X-Gateway-Key" => "tenant-1" }))

    client = Ai::Config.with(AiTestHelper.build_ai_config([ installed ], {})) do
      Eval::ProviderFactory.build(provider: "openai", model: "m", config: { uri_base: "http://127.0.0.1:8080/v1", access_token: "t" })
    end

    assert_empty client.ai_config(:categorize).models.sole.endpoint.extra_headers
  end

  test "runners slice samples by the measured model's batch size, not the installed route's" do
    installed = ai_model(endpoint: ai_endpoint(name: "openai_compatible"), name: "small", batch_size: 5)
    config = AiTestHelper.build_ai_config([ installed ], { categorize: %w[openai_compatible/small] })

    Ai::Config.with(config) do
      client = Eval::ProviderFactory.build(provider: "openai", model: "other", config: { uri_base: "http://127.0.0.1:8080/v1", access_token: "t" })

      assert_equal Ai::Config::Model::DEFAULT_BATCH_SIZE, Eval::GenerationClient.batch_size_for(client, :categorize)
      assert_equal 5, Eval::GenerationClient.batch_size_for(Object.new, :categorize)
    end
  end

  test "a native OpenAI host gets no local-model context window" do
    client = Eval::ProviderFactory.build(provider: "openai", model: "gpt-4.1", config: { uri_base: "https://us.api.openai.com/v1", access_token: "t" })

    assert_nil client.ai_config(:categorize).models.sole.context_window
  end
end
