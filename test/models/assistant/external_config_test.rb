require "test_helper"

class Assistant::ExternalConfigTest < ActiveSupport::TestCase
  test "config reads URL from environment with priority over Setting" do
    with_env_overrides("EXTERNAL_ASSISTANT_URL" => "http://from-env/v1/chat") do
      assert_equal "http://from-env/v1/chat", Assistant::External.config.url
      assert_equal "main", Assistant::External.config.agent_id
      assert_equal "agent:main:main", Assistant::External.config.session_key
    end
  end

  test "config falls back to Setting when env var is absent" do
    Setting.external_assistant_url = "http://from-setting/v1/chat"
    Setting.external_assistant_token = "setting-token"

    with_env_overrides("EXTERNAL_ASSISTANT_URL" => nil, "EXTERNAL_ASSISTANT_TOKEN" => nil) do
      assert_equal "http://from-setting/v1/chat", Assistant::External.config.url
      assert_equal "setting-token", Assistant::External.config.token
    end
  ensure
    Setting.external_assistant_url = nil
    Setting.external_assistant_token = nil
  end

  test "config reads agent_id with custom value" do
    with_env_overrides(
      "EXTERNAL_ASSISTANT_URL" => "http://example.com/v1/chat",
      "EXTERNAL_ASSISTANT_TOKEN" => "test-token",
      "EXTERNAL_ASSISTANT_AGENT_ID" => "finance-bot"
    ) do
      assert_equal "finance-bot", Assistant::External.config.agent_id
      assert_equal "test-token", Assistant::External.config.token
    end
  end

  test "config reads session_key with custom value" do
    with_env_overrides(
      "EXTERNAL_ASSISTANT_URL" => "http://example.com/v1/chat",
      "EXTERNAL_ASSISTANT_TOKEN" => "test-token",
      "EXTERNAL_ASSISTANT_SESSION_KEY" => "agent:finance-bot:finance"
    ) do
      assert_equal "agent:finance-bot:finance", Assistant::External.config.session_key
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

  test "build_conversation_messages trims to the configured token budget, keeping the newest" do
    chat = chats(:one)

    # ~40 tokens per message (see Assistant::TokenEstimator); a tight budget
    # should drop the oldest ones rather than truncating by a flat count.
    30.times do |i|
      role_class = i.even? ? UserMessage : AssistantMessage
      role_class.create!(chat: chat, content: "msg #{i} " + ("x" * 90), ai_model: "test")
    end

    with_env_overrides(
      "EXTERNAL_ASSISTANT_URL" => "http://x",
      "EXTERNAL_ASSISTANT_TOKEN" => "t",
      "EXTERNAL_ASSISTANT_MAX_HISTORY_TOKENS" => "200"
    ) do
      external = Assistant::External.new(chat)
      messages = external.send(:build_conversation_messages)

      assert_operator messages.length, :<, 30
      assert_match(/\Amsg 29 /, messages.last[:content])
      assert messages.none? { |m| m[:content].start_with?("msg 0 ") }
    end
  end

  test "build_conversation_messages keeps everything when the budget is generous" do
    chat = chats(:one)

    5.times do |i|
      role_class = i.even? ? UserMessage : AssistantMessage
      role_class.create!(chat: chat, content: "msg #{i}", ai_model: "test")
    end

    with_env_overrides("EXTERNAL_ASSISTANT_URL" => "http://x", "EXTERNAL_ASSISTANT_TOKEN" => "t") do
      external = Assistant::External.new(chat)
      messages = external.send(:build_conversation_messages)

      assert_equal 5, messages.length
      assert_equal "msg 4", messages.last[:content]
    end
  end

  test "max_history_tokens falls back to the default when unset or invalid" do
    with_env_overrides("EXTERNAL_ASSISTANT_MAX_HISTORY_TOKENS" => nil) do
      assert_equal Assistant::External::DEFAULT_MAX_HISTORY_TOKENS, Assistant::External.max_history_tokens
    end

    with_env_overrides("EXTERNAL_ASSISTANT_MAX_HISTORY_TOKENS" => "not-a-number") do
      assert_equal Assistant::External::DEFAULT_MAX_HISTORY_TOKENS, Assistant::External.max_history_tokens
    end
  end

  test "max_history_tokens reads a configured positive value" do
    with_env_overrides("EXTERNAL_ASSISTANT_MAX_HISTORY_TOKENS" => "1000") do
      assert_equal 1000, Assistant::External.max_history_tokens
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
