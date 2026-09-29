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

  test "gets new chat with a localized German default title" do
    @user.update!(locale: "de")

    travel_to Time.zone.local(2026, 8, 29, 12, 34) do
      get new_chat_url

      assert_response :success
      assert_select "turbo-frame#title_chat h3", text: "Neuer Chat 2026-08-29 12:34"
    end
  end

  test "gets new chat with the existing English default title" do
    @user.update!(locale: "en")

    travel_to Time.zone.local(2026, 8, 29, 12, 34) do
      get new_chat_url

      assert_response :success
      assert_select "turbo-frame#title_chat h3", text: "New chat 2026-08-29 12:34"
    end
  end

  test "creates chat" do
    assert_difference("Chat.count") do
      post chats_url, params: { chat: { content: "Hello", ai_model: "gpt-4.1" } }
    end

    chat = Chat.order(created_at: :desc).first

    assert_redirected_to chat_path(chat, thinking: true)
    assert_equal "Hello", chat.title
    assert_equal "Hello", chat.messages.find_by!(type: "UserMessage").content
  end

  test "shows chat" do
    chat = chats(:one)
    @user.update!(last_viewed_chat: nil)

    get chat_url(chat)

    assert_response :success
    assert_equal chat, @user.reload.last_viewed_chat
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
