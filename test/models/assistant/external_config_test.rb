require "test_helper"

class Assistant::ExternalConfigTest < ActiveSupport::TestCase
  test "config reads URL from environment with priority over Setting" do
    with_env_overrides("EXTERNAL_ASSISTANT_URL" => "http://from-env/v1/chat") do
      assert_equal "http://from-env/v1/chat", Assistant::External.config.url
      assert_equal "openclaw/main", Assistant::External.config.model
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

  test "config reads external model and derives the routing agent id" do
    with_env_overrides(
      "EXTERNAL_ASSISTANT_URL" => "http://example.com/v1/chat",
      "EXTERNAL_ASSISTANT_TOKEN" => "test-token",
      "EXTERNAL_ASSISTANT_MODEL" => "openclaw/finance-bot"
    ) do
      assert_equal "openclaw/finance-bot", Assistant::External.config.model
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
    with_env_overrides("EXTERNAL_ASSISTANT_URL" => "http://x", "EXTERNAL_ASSISTANT_TOKEN" => "t", "EXTERNAL_ASSISTANT_MODEL" => "openclaw/main", "EXTERNAL_ASSISTANT_ALLOWED_EMAILS" => nil) do
      assert Assistant::External.available_for?(user)
    end
  end

  test "available_for? restricts to allowlisted emails" do
    allowed = OpenStruct.new(email: "josh@example.com")
    denied = OpenStruct.new(email: "other@example.com")
    with_env_overrides("EXTERNAL_ASSISTANT_URL" => "http://x", "EXTERNAL_ASSISTANT_TOKEN" => "t", "EXTERNAL_ASSISTANT_MODEL" => "openclaw/main", "EXTERNAL_ASSISTANT_ALLOWED_EMAILS" => "josh@example.com, admin@example.com") do
      assert Assistant::External.available_for?(allowed)
      assert_not Assistant::External.available_for?(denied)
    end
  end

  test "build_conversation_messages truncates to last 20 messages" do
    chat = chats(:one)

    # Create enough messages to exceed the 20-message cap
    25.times do |i|
      role_class = i.even? ? UserMessage : AssistantMessage
      role_class.create!(chat: chat, content: "msg #{i}", ai_model: "test")
    end

    with_env_overrides("EXTERNAL_ASSISTANT_URL" => "http://x", "EXTERNAL_ASSISTANT_TOKEN" => "t") do
      external = Assistant::External.new(chat)
      messages = external.send(:build_conversation_messages)

      assert_equal 20, messages.length
      # Last message should be the most recent one we created
      assert_equal "msg 24", messages.last[:content]
    end
  end

  test "configured? returns true only when URL and token are both present" do
    Setting.external_assistant_url = nil
    Setting.external_assistant_token = nil

    with_env_overrides("EXTERNAL_ASSISTANT_URL" => "http://x", "EXTERNAL_ASSISTANT_TOKEN" => nil) do
      assert_not Assistant::External.configured?
    end

    # URL + token installs keep the pre-discovery implicit "main" agent.
    with_env_overrides("EXTERNAL_ASSISTANT_URL" => "http://x", "EXTERNAL_ASSISTANT_TOKEN" => "t", "EXTERNAL_ASSISTANT_MODEL" => nil, "EXTERNAL_ASSISTANT_AGENT_ID" => nil) do
      assert Assistant::External.configured?
      assert_equal "openclaw/main", Assistant::External.config.model
    end

    with_env_overrides("EXTERNAL_ASSISTANT_URL" => "http://x", "EXTERNAL_ASSISTANT_TOKEN" => "t", "EXTERNAL_ASSISTANT_MODEL" => "openclaw/main") do
      assert Assistant::External.configured?
    end
  end

  test "legacy agent id maps to a model only while no model is selected" do
    with_env_overrides("EXTERNAL_ASSISTANT_MODEL" => nil, "EXTERNAL_ASSISTANT_AGENT_ID" => "finance-bot") do
      assert_equal "openclaw/finance-bot", Assistant::External.config.model
      assert_equal "finance-bot", Assistant::External.config.agent_id
    end

    with_env_overrides("EXTERNAL_ASSISTANT_MODEL" => "openclaw/research", "EXTERNAL_ASSISTANT_AGENT_ID" => "finance-bot") do
      assert_equal "openclaw/research", Assistant::External.config.model
      assert_equal "research", Assistant::External.config.agent_id
    end
  end

  test "selected model wins over a stale stored legacy agent id" do
    Setting.external_assistant_agent_id = "old-bot"
    Setting.external_assistant_model = "openclaw/new-bot"

    with_env_overrides("EXTERNAL_ASSISTANT_MODEL" => nil, "EXTERNAL_ASSISTANT_AGENT_ID" => nil) do
      assert_equal "openclaw/new-bot", Assistant::External.config.model
      assert_equal "new-bot", Assistant::External.config.agent_id
    end
  ensure
    Setting.external_assistant_agent_id = nil
    Setting.external_assistant_model = nil
  end
end
