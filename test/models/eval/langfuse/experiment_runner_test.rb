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

  test "builds a jev provider" do
    built = runner(
      provider: "jev",
      model: "~typesafe/jev-latest",
      provider_config: { "api_key" => "test-key" }
    ).send(:build_provider)

    assert_instance_of Provider::Jev, built
  end

  test "passes jev endpoint and concurrency through from provider config" do
    Provider::Jev.expects(:new).with(
      "test-key",
      endpoint: "https://api.typesafe.ai/v1/systemone",
      model: "jev-latest",
      concurrency: 4
    )

    runner(
      provider: "jev",
      model: "jev-latest",
      provider_config: {
        "api_key" => "test-key",
        "endpoint" => "https://api.typesafe.ai/v1/systemone",
        "concurrency" => 4
      }
    ).send(:build_provider)
  end

  test "raises when jev has no api key configured" do
    Provider::Jev.stubs(:api_key).returns(nil)

    error = assert_raises(Eval::ProviderFactory::Error) do
      runner(provider: "jev", model: "jev-latest").send(:build_provider)
    end

    assert_match(/Jev API key not configured/, error.message)
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
