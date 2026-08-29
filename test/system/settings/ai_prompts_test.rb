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

  test "shows default status caption on load and custom caption when edited" do
    visit settings_ai_prompts_path

    all("summary").first.click
    editor = all("[data-controller='ai-prompt-editor']").first

    within editor do
      assert_text "Using the built-in default"
      assert find_button("Reset to default")[:disabled]

      fill_in "Prompt", with: "Custom text"

      assert_text "Using your custom prompt"
      assert_not find_button("Reset to default")[:disabled]
    end
  end

  test "user can edit both provider prompts from one editor" do
    visit settings_ai_prompts_path

    all("summary").first.click
    editor = all("[data-controller='ai-prompt-editor']").first
    anthropic_default = @user.family.ai_prompt_default(:categorizer_anthropic)

    within editor do
      fill_in "Prompt", with: "OpenAI prompt"
      click_button "OpenAI"
      click_on "Anthropic"
      assert_equal anthropic_default, find("textarea").value
      fill_in "Prompt", with: "Anthropic prompt"
    end

    click_button "Save prompts"

    @user.family.reload
    assert_equal "OpenAI prompt", @user.family.ai_prompt(:categorizer_openai)
    assert_equal "Anthropic prompt", @user.family.ai_prompt(:categorizer_anthropic)
  end

  test "resetting prompt confirms with custom modal and restores default text" do
    visit settings_ai_prompts_path

    all("summary").first.click
    editor = all("[data-controller='ai-prompt-editor']").first
    default_text = @user.family.ai_prompt_default(:categorizer_openai)

    within editor do
      fill_in "Prompt", with: "Temporary custom prompt"
      assert_text "Using your custom prompt"
      click_button "Reset to default"
    end

    assert_selector "#confirm-dialog", visible: true
    within "#confirm-dialog" do
      click_button "Confirm"
    end
    assert_no_selector "#confirm-dialog"

    within editor do
      assert_equal default_text, find("textarea").value
      assert_text "Using the built-in default"
      assert find_button("Reset to default")[:disabled]
    end
  end
end
