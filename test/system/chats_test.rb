require "application_system_test_case"

class ChatsTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    login_as(@user)
  end

  test "sidebar shows consent if ai is disabled for user" do
    @user.update!(ai_enabled: false)

    visit root_path

    within "#chat-container" do
      assert_selector "h3", text: "Enable AI Chats"
    end
  end

  # Regression test: the mobile bottom-nav "Assistant" item links straight to
  # `/chats`, which has no sidebar to gate. Before this fix that page rendered
  # the compose form unconditionally, letting a user without AI consent send
  # one message (via the unguarded ChatsController#create) before every
  # follow-up message silently 403'd.
  test "chats page shows consent instead of compose form when ai is disabled" do
    @user.update!(ai_enabled: false)
    @user.chats.destroy_all

    visit chats_path

    assert_selector "h3", text: "Enable AI Chats"
    assert_no_selector "textarea[name='chat[content]']"
  end

  test "sidebar shows index when enabled and chats are empty" do
    with_env_overrides OPENAI_ACCESS_TOKEN: "test-token" do
      @user.update!(ai_enabled: true)
      @user.chats.destroy_all

      visit root_url

      within "#chat-container" do
        assert_selector "h1", text: "Chats"
      end
    end
  end

  test "sidebar shows last viewed chat" do
    with_env_overrides OPENAI_ACCESS_TOKEN: "test-token" do
      chat = @user.chats.first
      @user.update!(ai_enabled: true, last_viewed_chat: chat)

      visit root_url

      within "#chat-container" do
        assert_selector "h1", text: chat.title
      end
    end
  end

  test "create chat and navigate chats sidebar" do
    with_env_overrides OPENAI_ACCESS_TOKEN: "test-token" do
      @user.chats.destroy_all

      visit root_url

      Chat.any_instance.expects(:ask_assistant_later).once

      within "#chat-form" do
        fill_in "chat[content]", with: "Can you help with my finances?"
        find("button[type='submit']").click
      end

      assert_text "Can you help with my finances?"

      find("#chat-nav-back").click

      assert_selector "h1", text: "Chats"

      click_on @user.chats.reload.first.title

      assert_text "Can you help with my finances?"
    end
  end
end
