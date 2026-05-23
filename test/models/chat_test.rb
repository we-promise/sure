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
      assert_equal Provider::Openai::DEFAULT_MODEL, chat.messages.find_by!(type: "UserMessage").ai_model
    end
  end

  test "creates with default model when model is empty string" do
    prompt = "Test prompt"

    assert_difference "@user.chats.count", 1 do
      chat = @user.chats.start!(prompt, model: "")

      assert_equal 2, chat.messages.count
      assert_equal Provider::Openai::DEFAULT_MODEL, chat.messages.find_by!(type: "UserMessage").ai_model
    end
  end

  test "creates with configured model when OPENAI_MODEL env is set" do
    prompt = "Test prompt"

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
end
