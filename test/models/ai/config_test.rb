require "test_helper"

class Ai::ConfigTest < ActiveSupport::TestCase
  test "an endpoint normalises its values and probes by listing models by default" do
    endpoint = Ai::Config::Endpoint.new(name: :gpu, protocol: "compatible", base_url: "", location: "local", timeout_seconds: "300")

    assert_equal "gpu", endpoint.name
    assert_equal :compatible, endpoint.protocol
    assert_nil endpoint.base_url
    assert endpoint.local?
    assert_equal 300, endpoint.timeout_seconds
    assert_equal 0, endpoint.max_retries
    assert_equal :models, endpoint.probe_check
  end

  test "an endpoint refuses unknown protocols, locations and probe checks" do
    assert_raises(ArgumentError) { Ai::Config::Endpoint.new(name: "x", protocol: :grpc) }
    assert_raises(ArgumentError) { Ai::Config::Endpoint.new(name: "x", protocol: :compatible, location: :moon) }
    assert_raises(ArgumentError) { Ai::Config::Endpoint.new(name: "x", protocol: :compatible, probe_check: :ping) }
  end

  test "an endpoint never shows its key or header values" do
    endpoint = ai_endpoint(base_url: "https://user:pass@llm.example.test/v1?key=abc", api_key: "test-secret-value-1",
                           extra_headers: { "X-Api-Key" => "header-secret" })

    [ endpoint.inspect, endpoint.to_s, endpoint.to_event.to_s ].each do |shown|
      assert_not_includes shown, "test-secret-value-1"
      assert_not_includes shown, "header-secret"
      assert_not_includes shown, "pass"
    end
  end

  test "a model checks its capabilities and prices tokens when it has prices" do
    model = ai_model(capabilities: %i[tools streaming], input_cost_per_mtok: 1.0, output_cost_per_mtok: 4.0)

    assert model.capable?(:tools)
    assert model.capable?(%w[tools streaming])
    assert_not model.capable?(:vision)
    assert_in_delta 0.000014, model.cost_for(Ai::Tokens.new(input_tokens: 2, cache_read_tokens: 4, output_tokens: 2)), 1e-12
    assert_nil ai_model.cost_for(Ai::Tokens.new(input_tokens: 2))
    assert_raises(ArgumentError) { ai_model(capabilities: [ :telepathy ]) }
  end

  test "the snapshot is built once per request and rebuilt when an input changes" do
    Ai::LegacyEnvConfig.expects(:build).twice.returns(Ai::Config.new, Ai::Config.new)

    first = Ai::Config.current
    assert_same first, Ai::Config.current

    with_env_overrides("OPENAI_MODEL" => "gpt-4.1-nano") do
      assert_not_same first, Ai::Config.current
    end
  end

  test "with uses another snapshot inside the block only" do
    other = Ai::Config.new
    Ai::Config.with(other) { assert_same other, Ai::Config.current }
    assert_not_same other, Ai::Config.current
  end

  test "routes are listed per feature, in order" do
    config = AiTestHelper.test_config

    assert_equal %w[gpt-4.1-mini openclaw/main], config.routes_for(:chat).map { _1.model.name }
    assert_equal [], config.routes_for(:search_documents)
    assert_equal "gpu", config.endpoint(:gpu).name
    assert_equal "qwen3-8b", config.model(:gpu, "qwen3-8b").name
  end
end
