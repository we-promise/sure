require "test_helper"

class MessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @chat = @user.chats.first
  end

  test "can create a message" do
    post chat_messages_url(@chat), params: { message: { content: "Hello", ai_model: "gpt-4.1" } }

    assert_redirected_to chat_path(@chat, thinking: true)
  end

  test "redirects to chats when message save races with chat deletion" do
    UserMessage.any_instance.stubs(:save).raises(ActiveRecord::InvalidForeignKey)

    post chat_messages_url(@chat), params: { message: { content: "Hello", ai_model: "gpt-4.1" } }

    assert_redirected_to chats_path
    assert_equal I18n.t("messages.create.chat_not_found"), flash[:alert]
  end

  test "cannot create a message if AI is disabled" do
    @user.update!(ai_enabled: false)

    post chat_messages_url(@chat), params: { message: { content: "Hello", ai_model: "gpt-4.1" } }

    assert_response :forbidden
  end

  test "report_timeout fails an undelivered assistant message" do
    BackgroundJobHealth.stubs(:snapshot).returns({})
    BackgroundJobHealth.stubs(:summary).returns("")

    pending = @chat.messages.create!(type: "AssistantMessage", content: "", ai_model: "gpt-4.1", status: :pending, created_at: 5.minutes.ago)

    post report_timeout_chat_message_url(@chat, pending)

    assert_response :ok
    assert_not Message.exists?(pending.id)
    assert @chat.reload.error.present?
  end

  # A client clock running ahead of the server's reports before the server floor
  # has elapsed. The response must not be 2xx: the watchdog stops retrying a URL
  # once it sees one, so an OK here would leave the bubble spinning forever.
  test "report_timeout declines retryably when the message is still too young" do
    Chat.stubs(:undelivered_response_timeout).returns(10.minutes)

    pending = @chat.messages.create!(type: "AssistantMessage", content: "", ai_model: "gpt-4.1", status: :pending, created_at: 5.minutes.ago)

    post report_timeout_chat_message_url(@chat, pending)

    assert_response :conflict
    assert pending.reload.pending?
    assert_nil @chat.reload.error
  end

  # The same bubble must resolve once it genuinely ages past the floor, so an
  # early report costs a retry rather than stranding the message.
  test "report_timeout succeeds on a later retry once the message is old enough" do
    BackgroundJobHealth.stubs(:snapshot).returns({})
    BackgroundJobHealth.stubs(:summary).returns("")

    pending = @chat.messages.create!(type: "AssistantMessage", content: "", ai_model: "gpt-4.1", status: :pending, created_at: 5.minutes.ago)

    Chat.stubs(:undelivered_response_timeout).returns(10.minutes)
    post report_timeout_chat_message_url(@chat, pending)
    assert_response :conflict

    Chat.stubs(:undelivered_response_timeout).returns(1.minute)
    post report_timeout_chat_message_url(@chat, pending)
    assert_response :ok
    assert_not Message.exists?(pending.id)
  end

  test "report_timeout cannot touch another user's chat" do
    other_chat = users(:family_member).chats.first
    pending = other_chat.messages.create!(type: "AssistantMessage", content: "", ai_model: "gpt-4.1", status: :pending)

    post report_timeout_chat_message_url(other_chat, pending)

    assert_response :not_found
    assert Message.exists?(pending.id)
  end
end
