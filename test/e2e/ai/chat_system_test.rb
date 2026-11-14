require "application_system_test_case"

# The browser sends a question, the job answers it on Kilo (run here, so the test waits for the
# answer however long the free model takes), and the reopened chat shows it.
class AiE2eChatSystemTest < ApplicationSystemTestCase
  include AiE2eHelper, ActiveJob::TestHelper

  setup do
    @user = users(:family_admin)
    @user.update!(ai_enabled: true)
    @user.chats.destroy_all
    login_as(@user)
  end

  test "Kilo answers a chat question, looking up the family's data" do
    with_live_ai(ASSISTANT_TYPE: "builtin") do
      visit root_url
      within "#chat-form" do
        fill_in "chat[content]", with: "How many accounts do I have? Look it up with your tools."
        find("button[type='submit']").click
      end
      assert_text "How many accounts do I have?"

      perform_enqueued_jobs(only: AssistantResponseJob)
      chat = Chat.where(user: @user).sole
      answer = chat.messages.where(type: "AssistantMessage").where.not(content: [ nil, "" ]).last

      assert answer, "no answer: #{chat.reload.error.inspect}"
      assert_equal "complete", answer.status
      assert ToolCall.joins(:message).where(messages: { chat_id: chat.id }).exists?, "the assistant didn't call a tool"

      visit chat_path(chat)
      assert_selector "##{ActionView::RecordIdentifier.dom_id(answer)}", text: /\S/
    end

    assert_ai_usage(@user.family, :chat)
  end
end
