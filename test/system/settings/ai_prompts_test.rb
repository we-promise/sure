require "application_system_test_case"

class Settings::AiPromptsTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.update!(ai_enabled: true)
    login_as @user
  end

  test "user can disable ai assistant" do
    visit settings_ai_prompts_path

    click_button "Disable AI Assistant"

    sleep 5

    assert_current_path settings_ai_prompts_path
    @user.reload
    assert_not @user.ai_enabled?
  end
end
