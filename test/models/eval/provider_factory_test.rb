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

  test "a run on its own server gets a plain endpoint" do
    installed = ai_model(endpoint: ai_endpoint(name: "openai_compatible", extra_headers: { "X-Gateway-Key" => "tenant-1" }))

    client = Ai::Config.with(AiTestHelper.build_ai_config([ installed ], {})) do
      Eval::ProviderFactory.build(provider: "openai", model: "m", config: { uri_base: "http://127.0.0.1:8080/v1", access_token: "t" })
    end

    assert_empty client.ai_config(:categorize).models.sole.endpoint.extra_headers
  end
end
