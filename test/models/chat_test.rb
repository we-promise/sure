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

  test "creates with initial message" do
    prompt = "Test prompt"

    assert_difference "@user.chats.count", 1 do
      chat = @user.chats.start!(prompt, model: "gpt-4.1")

      assert_equal 1, chat.messages.count
      assert_equal 1, chat.messages.where(type: "UserMessage").count
    end
  end

  test "creates with default model when model is nil" do
    prompt = "Test prompt"

    assert_difference "@user.chats.count", 1 do
      chat = @user.chats.start!(prompt, model: nil)

      assert_equal 1, chat.messages.count
      assert_equal Provider::Openai::DEFAULT_MODEL, chat.messages.first.ai_model
    end
  end

  test "creates with default model when model is empty string" do
    prompt = "Test prompt"

    assert_difference "@user.chats.count", 1 do
      chat = @user.chats.start!(prompt, model: "")

      assert_equal 1, chat.messages.count
      assert_equal Provider::Openai::DEFAULT_MODEL, chat.messages.first.ai_model
    end
  end

  test "creates with configured model when OPENAI_MODEL env is set" do
    prompt = "Test prompt"

    with_env_overrides OPENAI_MODEL: "custom-model" do
      chat = @user.chats.start!(prompt, model: "")

      assert_equal "custom-model", chat.messages.first.ai_model
    end
  end
end
