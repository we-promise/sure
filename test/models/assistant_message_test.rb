require "test_helper"

class AssistantMessageTest < ActiveSupport::TestCase
  setup do
    @chat = chats(:one)
  end

  test "pending messages expose localized progress labels" do
    message = AssistantMessage.create!(
      chat: @chat,
      content: "",
      ai_model: "gpt-4.1",
      status: :pending,
      progress_state: "analyzing_data"
    )

    assert_equal I18n.t("chats.analyzing_data"), message.progress_state_label
  end

  test "mark_analyzing_data transitions pending messages" do
    message = AssistantMessage.create!(
      chat: @chat,
      content: "",
      ai_model: "gpt-4.1",
      status: :pending,
      progress_state: "thinking"
    )

    message.mark_analyzing_data!
    message.reload

    assert_equal "analyzing_data", message.progress_state
    assert_equal "pending", message.status
  end

  test "append_text clears progress state when pending message completes" do
    message = AssistantMessage.create!(
      chat: @chat,
      content: "",
      ai_model: "gpt-4.1",
      status: :pending,
      progress_state: "thinking"
    )

    message.append_text!("hello")
    message.reload

    assert_equal "complete", message.status
    assert_nil message.progress_state
  end

  test "broadcasts append after creation" do
    message = AssistantMessage.create!(chat: @chat, content: "Hello from assistant", ai_model: "gpt-4.1")
    message.update!(content: "updated")

    streams = capture_turbo_stream_broadcasts(@chat)
    assert_equal 2, streams.size
    assert_equal "append", streams.first["action"]
    assert_equal @chat.messages_target, streams.first["target"]
    assert_equal "update", streams.last["action"]
    assert_equal "assistant_message_#{message.id}", streams.last["target"]
  end
end
