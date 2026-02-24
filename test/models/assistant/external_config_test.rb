require "test_helper"

class Assistant::ExternalConfigTest < ActiveSupport::TestCase
  test "config reads URL from environment dynamically" do
    with_env_overrides("EXTERNAL_ASSISTANT_URL" => "http://localhost:18789/v1/chat/completions") do
      assert_equal "http://localhost:18789/v1/chat/completions", Assistant::External.config.url
      assert_nil Assistant::External.config.token
      assert_equal "main", Assistant::External.config.agent_id
    end

    # After env override is gone, config reflects that
    assert_nil Assistant::External.config.url
  end

  test "config reads agent_id with custom value" do
    with_env_overrides(
      "EXTERNAL_ASSISTANT_URL" => "http://example.com/v1/chat/completions",
      "EXTERNAL_ASSISTANT_TOKEN" => "test-token",
      "EXTERNAL_ASSISTANT_AGENT_ID" => "buster"
    ) do
      assert_equal "buster", Assistant::External.config.agent_id
      assert_equal "test-token", Assistant::External.config.token
    end
  end

  test "configured? returns true only when URL and token are both present" do
    with_env_overrides("EXTERNAL_ASSISTANT_URL" => "http://x", "EXTERNAL_ASSISTANT_TOKEN" => nil) do
      assert_not Assistant::External.configured?
    end

    with_env_overrides("EXTERNAL_ASSISTANT_URL" => "http://x", "EXTERNAL_ASSISTANT_TOKEN" => "t") do
      assert Assistant::External.configured?
    end
  end
end
