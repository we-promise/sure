require "test_helper"

class ChatsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = families(:dylan_family)
    sign_in @user
  end

  test "gets index" do
    get chats_url
    assert_response :success
  end

  test "creates chat using configured model" do
    Chat.stubs(:default_model).returns("gpt-4.1")

    assert_difference("Chat.count") do
      post chats_url, params: { chat: { content: "Hello" } }
    end

    assert_redirected_to chat_path(Chat.order(created_at: :desc).first, thinking: true)
    assert_equal "gpt-4.1", Chat.order(created_at: :desc).first.messages.ordered.last.ai_model
  end

  test "ignores any ai_model param from the form and uses only the configured model" do
    Chat.stubs(:default_model).returns("gpt-4.1")

    post chats_url, params: { chat: { content: "Hello", ai_model: "some-random-model" } }

    assert_redirected_to chat_path(Chat.order(created_at: :desc).first, thinking: true)
    assert_equal "gpt-4.1", Chat.order(created_at: :desc).first.messages.ordered.last.ai_model
  end

  test "renders new with error when no model is configured" do
    Chat.stubs(:default_model).returns(nil)

    assert_no_difference("Chat.count") do
      post chats_url, params: { chat: { content: "Hello" } }
    end

    assert_response :unprocessable_entity
    assert_equal I18n.t("chats.no_model_configured"), flash[:alert]
  end

  test "shows chat" do
    get chat_url(chats(:one))
    assert_response :success
  end

  test "retry updates last user message model to current default model" do
    with_self_hosting do
      chat = chats(:one)
      user_message = chat.messages.where(type: "UserMessage").ordered.last
      user_message.update!(ai_model: "llama-3.1-8b-instant")

      Chat.stubs(:default_model).returns("gpt-4.1-new")

      post retry_chat_url(chat)

      assert_redirected_to chat_path(chat, thinking: true)
      assert_equal "gpt-4.1-new", user_message.reload.ai_model
    end
  end

  test "destroys chat" do
    assert_difference("Chat.count", -1) do
      delete chat_url(chats(:one))
    end

    assert_redirected_to chats_url
  end

  test "should not allow access to other user's chats" do
    other_user = users(:family_member)
    other_chat = Chat.create!(user: other_user, title: "Other User's Chat")

    get chat_url(other_chat)
    assert_response :not_found

    delete chat_url(other_chat)
    assert_response :not_found
  end

end
