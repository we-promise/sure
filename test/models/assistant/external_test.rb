require "test_helper"

class Assistant::ExternalTest < ActiveSupport::TestCase
  setup do
    @chat = chats(:two)
  end

  test "responds with stub message" do
    external = Assistant::External.for_chat(@chat)

    message = @chat.messages.create!(
      type: "UserMessage",
      content: "Hello",
      ai_model: "gpt-4.1"
    )

    assert_difference "AssistantMessage.count", 1 do
      external.respond_to(message)
    end

    assistant_msg = @chat.messages.where(type: "AssistantMessage").last
    assert_includes assistant_msg.content, "External assistant is not yet configured"
  end

  test "handles errors gracefully" do
    external = Assistant::External.for_chat(@chat)

    message = @chat.messages.create!(
      type: "UserMessage",
      content: "Hello",
      ai_model: "gpt-4.1"
    )

    AssistantMessage.any_instance.stubs(:append_text!).raises(StandardError.new("connection failed"))

    external.respond_to(message)

    assert @chat.reload.error.present?
  end
end
