require "test_helper"

class Assistant::ExternalConfigTest < ActiveSupport::TestCase
  test "config reads URL from environment with priority over Setting" do
    with_env_overrides("EXTERNAL_ASSISTANT_URL" => "http://from-env/v1/chat/completions") do
      assert_equal "http://from-env/v1/chat/completions", Assistant::External.config.url
      assert_equal "main", Assistant::External.config.agent_id
      assert_equal "agent:main:main", Assistant::External.config.session_key
    end
  end

  test "config falls back to Setting when env var is absent" do
    Setting.external_assistant_url = "http://from-setting/v1/chat/completions"
    Setting.external_assistant_token = "setting-token"

    with_env_overrides("EXTERNAL_ASSISTANT_URL" => nil, "EXTERNAL_ASSISTANT_TOKEN" => nil) do
      assert_equal "http://from-setting/v1/chat/completions", Assistant::External.config.url
      assert_equal "setting-token", Assistant::External.config.token
    end
  ensure
    Setting.external_assistant_url = nil
    Setting.external_assistant_token = nil
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

  test "config reads session_key with custom value" do
    with_env_overrides(
      "EXTERNAL_ASSISTANT_URL" => "http://example.com/v1/chat/completions",
      "EXTERNAL_ASSISTANT_TOKEN" => "test-token",
      "EXTERNAL_ASSISTANT_SESSION_KEY" => "agent:buster:finance"
    ) do
      assert_equal "agent:buster:finance", Assistant::External.config.session_key
    end
  end

  test "available_for? allows any user when no allowlist is set" do
    user = OpenStruct.new(email: "anyone@example.com")
    with_env_overrides("EXTERNAL_ASSISTANT_URL" => "http://x", "EXTERNAL_ASSISTANT_TOKEN" => "t", "EXTERNAL_ASSISTANT_ALLOWED_EMAILS" => nil) do
      assert Assistant::External.available_for?(user)
    end
  end

  test "available_for? restricts to allowlisted emails" do
    allowed = OpenStruct.new(email: "josh@example.com")
    denied = OpenStruct.new(email: "other@example.com")
    with_env_overrides("EXTERNAL_ASSISTANT_URL" => "http://x", "EXTERNAL_ASSISTANT_TOKEN" => "t", "EXTERNAL_ASSISTANT_ALLOWED_EMAILS" => "josh@example.com, admin@example.com") do
      assert Assistant::External.available_for?(allowed)
      assert_not Assistant::External.available_for?(denied)
    end
  end

  test "configured? returns true only when URL and token are both present" do
    Setting.external_assistant_url = nil
    Setting.external_assistant_token = nil

    with_env_overrides("EXTERNAL_ASSISTANT_URL" => "http://x", "EXTERNAL_ASSISTANT_TOKEN" => nil) do
      assert_not Assistant::External.configured?
    end

    with_env_overrides("EXTERNAL_ASSISTANT_URL" => "http://x", "EXTERNAL_ASSISTANT_TOKEN" => "t") do
      assert Assistant::External.configured?
    end
  end
end
