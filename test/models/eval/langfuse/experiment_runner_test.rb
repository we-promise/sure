require "test_helper"

class Eval::Langfuse::ExperimentRunnerTest < ActiveSupport::TestCase
  setup do
    @dataset = Eval::Dataset.create!(
      name: "test_exp_#{SecureRandom.hex(4)}",
      eval_type: "categorization",
      version: "1.0"
    )
    @client = stub("langfuse_client")
  end

  def runner(provider:, model:, provider_config: {})
    Eval::Langfuse::ExperimentRunner.new(
      @dataset,
      model: model,
      provider: provider,
      client: @client,
      provider_config: provider_config
    )
  end

  test "reads provider config written with string keys" do
    # Regression: this class read provider_config with symbol keys while every
    # other spelling of the same config is string-keyed (Eval::Run#provider_config
    # is jsonb). A string-keyed caller silently fell through to ENV/Setting.
    Provider::Openai.expects(:new).with(
      "string-key-token",
      uri_base: "https://example.test/v1",
      model: "gpt-4.1"
    )

    runner(
      provider: "openai",
      model: "gpt-4.1",
      provider_config: { "access_token" => "string-key-token", "uri_base" => "https://example.test/v1" }
    ).send(:build_provider)
  end

  test "still reads provider config written with symbol keys" do
    Provider::Openai.expects(:new).with(
      "symbol-key-token",
      uri_base: nil,
      model: "gpt-4.1"
    )

    runner(
      provider: "openai",
      model: "gpt-4.1",
      provider_config: { access_token: "symbol-key-token", uri_base: nil }
    ).send(:build_provider)
  end

  test "builds a jev client on the judgement" do
    built = runner(provider: "jev", model: "jev-latest", provider_config: { "api_key" => "test-key" }).send(:build_provider)

    assert_instance_of Eval::GenerationClient, built
    route = built.ai_config(:categorize).routes_for(:categorize).sole
    assert route.judge?
    assert route.model.capable?(:calibrated_confidence)
  end

  test "passes jev endpoint and concurrency through from provider config" do
    built = runner(
      provider: "jev",
      model: "jev-latest",
      provider_config: { "api_key" => "test-key", "endpoint" => "http://jev:8080/v1/systemone", "concurrency" => 4 }
    ).send(:build_provider)

    endpoint = built.ai_config(:categorize).routes_for(:categorize).sole.endpoint
    assert_equal [ "http://jev:8080", 4, :jev_local ], [ endpoint.base_url, endpoint.parallel_requests, endpoint.preset ]
  end

  test "raises when jev has no api key configured, or an endpoint RubyLLM can't reach" do
    Ai::LegacyEnvConfig::Jev.stubs(:api_key).returns(nil)

    error = assert_raises(Eval::ProviderFactory::Error) do
      runner(provider: "jev", model: "jev-latest").send(:build_provider)
    end
    assert_match(/Jev API key not configured/, error.message)

    error = assert_raises(Eval::ProviderFactory::Error) do
      runner(provider: "jev", model: "~typesafe/jev-latest",
             provider_config: { "api_key" => "test-key", "endpoint" => "https://gw.example.test/v1/jev" }).send(:build_provider)
    end
    assert_match(/not supported/, error.message)
  end

  test "rejects an unknown provider" do
    error = assert_raises(Eval::ProviderFactory::Error) do
      runner(provider: "nonesuch", model: "x").send(:build_provider)
    end

    assert_match(/Unsupported provider: nonesuch/, error.message)
  end

  test "honors a json_mode written with string keys" do
    items = [ { "expectedOutput" => { "category_name" => "Food & Drink" } } ]

    effective = runner(
      provider: "openai",
      model: "gpt-4.1",
      provider_config: { "json_mode" => "strict" }
    ).send(:json_mode_for_batch, items)

    assert_equal "strict", effective
  end
end
