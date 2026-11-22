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

  test "a run on another server without its own token is refused, so the install's key never reaches it" do
    endpoint = ai_endpoint(name: "openai_compatible", base_url: "https://gateway.example.test/v1", api_key: "installed-key")

    error = assert_raises(Eval::ProviderFactory::Error) do
      Ai::Config.with(AiTestHelper.build_ai_config([ ai_model(endpoint:, name: "qwen3") ], {})) do
        Eval::ProviderFactory.build(provider: "openai", model: "qwen3", config: { uri_base: "https://other.example.test/v1" })
      end
    end
    assert_equal "OpenAI access token not configured", error.message
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

  test "the chat provider gets OPENAI_EXTRA_HEADERS on the configured gateway only" do
    headers = '{"X-Gateway-Key":"tenant-1","X-Session":"{session_id}"}'

    with_env_overrides("OPENAI_EXTRA_HEADERS" => headers, "OPENAI_URI_BASE" => "https://gateway.example.test/v1") do
      gateway = Eval::ProviderFactory.build(provider: "openai", model: "qwen3", config: { access_token: "t" })
      other = Eval::ProviderFactory.build(provider: "openai", model: "qwen3",
                                          config: { uri_base: "https://other.example.test/v1", access_token: "t" })

      assert_equal({ "X-Gateway-Key" => "tenant-1" }, chat_client(gateway).extra_headers)
      assert_equal({ "X-Session" => "{session_id}" }, chat_provider(gateway).instance_variable_get(:@session_extra_headers))
      assert_empty chat_client(other).extra_headers.to_h
      assert_empty chat_provider(other).instance_variable_get(:@session_extra_headers)
    end
  end

  private
    def chat_provider(client) = client.send(:chat_provider)

    def chat_client(client) = chat_provider(client).instance_variable_get(:@client)
end
