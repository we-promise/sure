require "test_helper"

class ChatTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @assistant = mock
  end

  test "user sees all messages in debug mode" do
    chat = chats(:one)
    with_env_overrides AI_DEBUG_MODE: "true" do
      assert_equal chat.messages.count, chat.conversation_messages.count
    end
  end

  test "user sees assistant and user messages in normal mode" do
    chat = chats(:one)
    assert_equal 3, chat.conversation_messages.count
  end

  test "uses chat-scoped stream targets" do
    first_chat = chats(:one)
    second_chat = chats(:two)

    assert_not_equal "messages", first_chat.messages_target
    assert_not_equal "chat-error", first_chat.error_target
    assert_not_equal first_chat.messages_target, second_chat.messages_target
    assert_not_equal first_chat.error_target, second_chat.error_target
  end

  test "creates with initial message" do
    prompt = "Test prompt"

    assert_difference "@user.chats.count", 1 do
      chat = @user.chats.start!(prompt, model: "gpt-4.1")

      assert_equal 2, chat.messages.count
      assert_equal 1, chat.messages.where(type: "UserMessage").count
      assert_equal 1, chat.messages.where(type: "AssistantMessage", status: "pending").count
    end
  end

  test "creates with default model when model is nil" do
    prompt = "Test prompt"

    assert_difference "@user.chats.count", 1 do
      chat = @user.chats.start!(prompt, model: nil)

      assert_equal 2, chat.messages.count
      assert_equal Chat.default_model, chat.messages.find_by!(type: "UserMessage").ai_model
    end
  end

  test "creates with default model when model is empty string" do
    prompt = "Test prompt"

    assert_difference "@user.chats.count", 1 do
      chat = @user.chats.start!(prompt, model: "")

      assert_equal 2, chat.messages.count
      assert_equal Chat.default_model, chat.messages.find_by!(type: "UserMessage").ai_model
    end
  end

  # These three tests assert routing (which provider's effective_model wins),
  # not the constant value itself — the assertion side reads through
  # Provider::*.effective_model so ENV overrides like ANTHROPIC_MODEL /
  # OPENAI_MODEL don't make the tests flake.
  test "default_model returns Anthropic's effective_model when LLM_PROVIDER=anthropic and Anthropic is configured" do
    Provider::Anthropic.stubs(:configured?).returns(true)
    Setting.stubs(:llm_provider).returns("anthropic")

    assert_equal Provider::Anthropic.effective_model, Chat.default_model
  end

  test "default_model falls back to OpenAI's effective_model when Anthropic is preferred but unconfigured" do
    Provider::Anthropic.stubs(:configured?).returns(false)
    Provider::Openai.stubs(:configured?).returns(true)
    Setting.stubs(:llm_provider).returns("anthropic")

    assert_equal Provider::Openai.effective_model, Chat.default_model
  end

  test "default_model uses Anthropic's effective_model when OpenAI is unconfigured" do
    Provider::Anthropic.stubs(:configured?).returns(true)
    Provider::Openai.stubs(:configured?).returns(false)
    Setting.stubs(:llm_provider).returns("openai")

    assert_equal Provider::Anthropic.effective_model, Chat.default_model
  end

  test "creates with configured model when OPENAI_MODEL env is set" do
    prompt = "Test prompt"

    # Pin the active provider to OpenAI so default_model resolution is
    # deterministic regardless of which provider credentials the environment
    # happens to have configured (otherwise a configured Anthropic key makes
    # default_model fall through to claude-sonnet-4-6).
    Setting.stubs(:llm_provider).returns("openai")
    Provider::Openai.stubs(:configured?).returns(true)

    with_env_overrides OPENAI_MODEL: "custom-model" do
      chat = @user.chats.start!(prompt, model: "")

      assert_equal "custom-model", chat.messages.find_by!(type: "UserMessage").ai_model
    end
  end

  test "returns nil presentable error message when no error is stored" do
    chat = chats(:one)

    chat.update!(error: nil)

    assert_nil chat.presentable_error_message
  end

  test "surfaces a friendly rate limit error" do
    chat = chats(:one)

    chat.add_error(StandardError.new("OpenAI API error 429: rate limit exceeded"))

    assert_equal I18n.t("chat.errors.rate_limited"), chat.presentable_error_message
    assert_match "429", chat.technical_error_message
  end

  test "surfaces a friendly temporary provider error" do
    chat = chats(:one)

    chat.add_error(StandardError.new("OpenAI API error 503: service unavailable"))

    assert_equal I18n.t("chat.errors.temporarily_unavailable"), chat.presentable_error_message
    assert_match "503", chat.technical_error_message
  end

  test "surfaces a friendly auth configuration error" do
    chat = chats(:one)

    chat.add_error(StandardError.new("OpenAI API error: invalid api key"))

    assert_equal I18n.t("chat.errors.misconfigured"), chat.presentable_error_message
    assert_match "invalid api key", chat.technical_error_message
  end

  test "surfaces a friendly default error for unrecognized errors" do
    chat = chats(:one)

    chat.add_error(StandardError.new("something totally unknown happened"))

    assert_equal I18n.t("chat.errors.default"), chat.presentable_error_message
  end

  test "falls back to a friendly message for legacy serialized errors" do
    chat = chats(:one)

    chat.update!(error: "OpenAI API error 429: rate limit exceeded".to_json)

    assert_equal I18n.t("chat.errors.rate_limited"), chat.presentable_error_message
    assert_equal "OpenAI API error 429: rate limit exceeded", chat.technical_error_message
  end

  test "handle_undelivered_response! clears a blank pending bubble and records an error + debug log" do
    BackgroundJobHealth.stubs(:snapshot).returns({ healthy: false, workers: 0 })
    BackgroundJobHealth.stubs(:summary).returns("workers=0")

    chat = chats(:two)
    pending = chat.messages.create!(type: "AssistantMessage", content: "", ai_model: "gpt-4.1", status: :pending, created_at: 5.minutes.ago)

    assert_difference -> { DebugLogEntry.count } => 1, -> { Message.count } => -1 do
      assert chat.handle_undelivered_response!(pending)
    end

    assert_not Message.exists?(pending.id)
    assert_equal I18n.t("chat.errors.no_response"), chat.reload.presentable_error_message
  end

  test "handle_undelivered_response! demotes a partially-streamed pending bubble to failed" do
    BackgroundJobHealth.stubs(:snapshot).returns({})
    BackgroundJobHealth.stubs(:summary).returns("")

    chat = chats(:two)
    pending = chat.messages.create!(type: "AssistantMessage", content: "partial answer", ai_model: "gpt-4.1", status: :pending, created_at: 5.minutes.ago)

    assert_no_difference -> { Message.count } do
      assert chat.handle_undelivered_response!(pending)
    end

    assert_equal "failed", pending.reload.status
  end

  test "handle_undelivered_response! ignores a pending bubble younger than the server timeout" do
    chat = chats(:two)
    fresh = chat.messages.create!(type: "AssistantMessage", content: "", ai_model: "gpt-4.1", status: :pending, created_at: 5.seconds.ago)

    assert_no_difference [ "DebugLogEntry.count", "Message.count" ] do
      assert_not chat.handle_undelivered_response!(fresh)
    end

    assert fresh.reload.pending?
  end

  test "handle_undelivered_response! is a no-op for non-pending messages" do
    chat = chats(:one)
    complete = chat.messages.create!(type: "AssistantMessage", content: "done", ai_model: "gpt-4.1", status: :complete)

    assert_no_difference [ "DebugLogEntry.count", "Message.count" ] do
      assert_not chat.handle_undelivered_response!(complete)
    end
  end
end
