require "test_helper"

class MessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @chat = @user.chats.first
  end

  test "can create a message using configured model" do
    Chat.stubs(:default_model).returns("gpt-4.1")

    post chat_messages_url(@chat), params: { message: { content: "Hello" } }

    assert_redirected_to chat_path(@chat, thinking: true)
    assert_equal "gpt-4.1", @chat.messages.ordered.last.ai_model
  end

  test "ignores any ai_model param and uses only the configured model" do
    Chat.stubs(:default_model).returns("gpt-4.1")

    post chat_messages_url(@chat), params: { message: { content: "Hello", ai_model: "some-random-model" } }

    assert_redirected_to chat_path(@chat, thinking: true)
    assert_equal "gpt-4.1", @chat.messages.ordered.last.ai_model
  end

  test "renders show with error when no model is configured" do
    Chat.stubs(:default_model).returns(nil)

    assert_no_difference("UserMessage.count") do
      post chat_messages_url(@chat), params: { message: { content: "Hello" } }
    end

    assert_response :unprocessable_entity
    assert_equal I18n.t("chats.no_model_configured"), flash[:alert]
  end

  test "cannot create a message if AI is disabled" do
    @user.update!(ai_enabled: false)

    post chat_messages_url(@chat), params: { message: { content: "Hello", ai_model: "gpt-4.1" } }

    assert_response :forbidden
  end
end
