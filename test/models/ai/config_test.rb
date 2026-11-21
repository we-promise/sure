require "test_helper"

class Ai::ConfigTest < ActiveSupport::TestCase
  test "an endpoint never shows its key or header values" do
    endpoint = ai_endpoint(base_url: "https://user:pass@llm.example.test/v1?key=abc", api_key: "test-secret-value-1",
                           extra_headers: { "X-Api-Key" => "header-secret" })

    [ endpoint.inspect, endpoint.to_s, endpoint.to_event.to_s ].each do |shown|
      assert_not_includes shown, "test-secret-value-1"
      assert_not_includes shown, "header-secret"
      assert_not_includes shown, "pass"
    end
  end

  test "the snapshot is built once per request and rebuilt when an input changes" do
    Ai::LegacyEnvConfig.expects(:build).twice.returns(Ai::Config.new, Ai::Config.new)

    first = Ai::Config.current
    assert_same first, Ai::Config.current

    with_env_overrides("OPENAI_MODEL" => "gpt-4.1-nano") do
      assert_not_same first, Ai::Config.current
    end
  end
end
