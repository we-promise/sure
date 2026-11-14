require "test_helper"

class Ai::ConfigTest < ActiveSupport::TestCase
  test "an endpoint normalises its values and probes by listing models by default" do
    endpoint = Ai::Config::Endpoint.new(name: :gpu, protocol: "compatible", base_url: "", timeout_seconds: "300")

    assert_equal "gpu", endpoint.name
    assert_equal :compatible, endpoint.protocol
    assert_nil endpoint.base_url
    assert_equal 300, endpoint.timeout_seconds
    assert_equal 0, endpoint.max_retries
    assert_equal :models, endpoint.probe_check
  end

  test "an endpoint refuses unknown protocols and probe checks" do
    assert_raises(ArgumentError) { Ai::Config::Endpoint.new(name: "x", protocol: :grpc) }
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
end
