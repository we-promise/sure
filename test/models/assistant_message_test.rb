require "test_helper"

class AssistantMessageTest < ActiveSupport::TestCase
  setup do
    @chat = chats(:one)
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

  test "append_text! streams into a pending bubble" do
    message = AssistantMessage.create!(chat: @chat, content: "", ai_model: "gpt-4.1", status: :pending)

    assert message.append_text!("Hello")
    assert_equal "Hello", message.reload.content
    assert message.complete?
  end

  # The watchdog runs in the web process; a slow job holds its own copy of the
  # message and must not resurrect a bubble the user was already told failed.
  test "append_text! refuses to resurrect a bubble the watchdog already cleared" do
    message = AssistantMessage.create!(chat: @chat, content: "", ai_model: "gpt-4.1", status: :pending)
    job_copy = AssistantMessage.find(message.id)

    message.destroy!

    assert_not job_copy.append_text!("late response")
    assert_not Message.exists?(job_copy.id)
  end

  test "append_text! refuses to resurrect a bubble the watchdog demoted to failed" do
    message = AssistantMessage.create!(chat: @chat, content: "", ai_model: "gpt-4.1", status: :pending)
    job_copy = AssistantMessage.find(message.id)

    message.update_columns(status: "failed")

    assert_not job_copy.append_text!("late response")
    assert_equal "failed", message.reload.status
    assert_equal "", message.content
  end

  # Only the first append claims the row, so a streaming response does not pay
  # for the conditional UPDATE on every chunk.
  test "append_text! claims the pending row once, then appends in place" do
    message = AssistantMessage.create!(chat: @chat, content: "", ai_model: "gpt-4.1", status: :pending)

    assert message.append_text!("Hello")
    assert message.append_text!(" world")

    assert_equal "Hello world", message.reload.content
    assert message.complete?
  end

  test "broadcasts remove after destroy so a failed turn's bubble is cleared" do
    message = AssistantMessage.create!(chat: @chat, content: "Hello from assistant", ai_model: "gpt-4.1")
    message.destroy!

    streams = capture_turbo_stream_broadcasts(@chat)
    assert_equal "remove", streams.last["action"]
    assert_equal "assistant_message_#{message.id}", streams.last["target"]
  end
end
