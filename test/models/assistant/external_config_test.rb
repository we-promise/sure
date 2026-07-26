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

  test "build_conversation_messages keeps every complete message that fits the token budget" do
    chat = chats(:one)

    # Create messages well beyond the old 20-message cap to verify it's gone
    25.times do |i|
      role_class = i.even? ? UserMessage : AssistantMessage
      role_class.create!(chat: chat, content: "msg #{i}", ai_model: "test")
    end

    expected_count = chat.conversation_messages.where(status: "complete").count

    with_env_overrides("EXTERNAL_ASSISTANT_URL" => "http://x", "EXTERNAL_ASSISTANT_TOKEN" => "t") do
      external = Assistant::External.new(chat)
      messages = external.send(:build_conversation_messages)

      assert_equal expected_count, messages.length, "Expected all complete messages to be included"
      # Last message should be the most recent one we created
      assert_equal "msg 24", messages.last[:content]
    end
  end

  test "build_conversation_messages drops the oldest messages once the token budget is exceeded" do
    chat = chats(:one)

    10.times do |i|
      role_class = i.even? ? UserMessage : AssistantMessage
      role_class.create!(chat: chat, content: "msg #{i} #{'x' * 200}", ai_model: "test")
    end

    total_count = chat.conversation_messages.where(status: "complete").count

    with_env_overrides(
      "EXTERNAL_ASSISTANT_URL" => "http://x",
      "EXTERNAL_ASSISTANT_TOKEN" => "t",
      "EXTERNAL_ASSISTANT_MAX_HISTORY_TOKENS" => "256"
    ) do
      messages = Assistant::External.new(chat).send(:build_conversation_messages)

      assert_operator messages.length, :<, total_count
      assert messages.last[:content].start_with?("msg 9"), "newest message must be kept"
      assert messages.none? { |m| m[:content].start_with?("msg 0") }, "oldest messages must be dropped"
    end
  end

  test "build_conversation_messages still sends the newest message when it alone exceeds the budget" do
    chat = chats(:one)
    oversized = "x" * 5_000
    UserMessage.create!(chat: chat, content: oversized, ai_model: "test")

    with_env_overrides(
      "EXTERNAL_ASSISTANT_URL" => "http://x",
      "EXTERNAL_ASSISTANT_TOKEN" => "t",
      "EXTERNAL_ASSISTANT_MAX_HISTORY_TOKENS" => "256"
    ) do
      messages = Assistant::External.new(chat).send(:build_conversation_messages)

      assert_equal 1, messages.length
      assert_equal oversized, messages.last[:content]
    end
  end

  test "max_history_tokens falls back to the default and floors small overrides" do
    chat = chats(:one)

    with_env_overrides("EXTERNAL_ASSISTANT_MAX_HISTORY_TOKENS" => nil) do
      assert_equal Assistant::External::DEFAULT_MAX_HISTORY_TOKENS,
        Assistant::External.new(chat).send(:max_history_tokens)
    end

    with_env_overrides("EXTERNAL_ASSISTANT_MAX_HISTORY_TOKENS" => "4096") do
      assert_equal 4096, Assistant::External.new(chat).send(:max_history_tokens)
    end

    with_env_overrides("EXTERNAL_ASSISTANT_MAX_HISTORY_TOKENS" => "10") do
      assert_equal Assistant::External::MIN_MAX_HISTORY_TOKENS,
        Assistant::External.new(chat).send(:max_history_tokens)
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
