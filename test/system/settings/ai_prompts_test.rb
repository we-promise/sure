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
      assert_text "/ 20,000"
      assert find_button("Reset to default", disabled: true)

      find("textarea").fill_in with: "Custom text 😀"

      assert_text "Using your custom prompt"
      assert_text "13 / 20,000"
      assert find_button("Reset to default")
    end
  end

  test "user can edit both provider prompts from one editor" do
    visit settings_ai_prompts_path

    all("summary", minimum: 3)[1].click
    editor = find("[data-controller='ai-prompt-editor']")
    anthropic_default = @user.family.ai_prompt_default(:categorizer_anthropic)

    within editor do
      fill_in "Prompt", with: "OpenAI prompt"
      click_button "OpenAI"
      find("[role='option']", text: "Anthropic").click
      assert_equal anthropic_default, find("textarea").value
      fill_in "Prompt", with: "Anthropic prompt"
    end

    click_button "Save prompts"

    assert_selector "#ai-prompt-save-confirm-dialog", visible: true
    within "#ai-prompt-save-confirm-dialog" do
      click_button "Confirm"
    end
    assert_no_selector "#ai-prompt-save-confirm-dialog"

    assert_text "AI prompts updated"

    @user.family.reload
    assert_equal "OpenAI prompt", @user.family.ai_prompt(:categorizer_openai)
    assert_equal "Anthropic prompt", @user.family.ai_prompt(:categorizer_anthropic)
  end

  test "saving custom prompt can be cancelled via save confirmation dialog" do
    visit settings_ai_prompts_path

    all("summary", minimum: 3)[1].click
    editor = find("[data-controller='ai-prompt-editor']")

    within editor do
      fill_in "Prompt", with: "Unsaved prompt"
    end

    click_button "Save prompts"

    assert_selector "#ai-prompt-save-confirm-dialog", visible: true
    within "#ai-prompt-save-confirm-dialog" do
      click_button "Cancel"
    end
    assert_no_selector "#ai-prompt-save-confirm-dialog"
    assert_no_text "AI prompts updated"

    assert_nil @user.family.reload.ai_prompt(:categorizer_openai)
  end

  test "saving custom prompt with dont show again remembers preference in subsequent saves" do
    visit settings_ai_prompts_path

    all("summary", minimum: 3)[1].click
    editor = find("[data-controller='ai-prompt-editor']")

    within editor do
      fill_in "Prompt", with: "First custom prompt"
    end

    click_button "Save prompts"

    assert_selector "#ai-prompt-save-confirm-dialog", visible: true
    within "#ai-prompt-save-confirm-dialog" do
      check "Don't show this warning again"
      click_button "Confirm"
    end
    assert_no_selector "#ai-prompt-save-confirm-dialog"
    assert_text "AI prompts updated"

    # Subsequent save with another custom prompt should bypass the dialog
    all("summary", minimum: 3)[1].click
    editor = find("[data-controller='ai-prompt-editor']")
    within editor do
      fill_in "Prompt", with: "Second custom prompt"
    end

    click_button "Save prompts"
    assert_no_selector "#ai-prompt-save-confirm-dialog"
    assert_text "AI prompts updated"
    assert_equal "Second custom prompt", @user.family.reload.ai_prompt(:categorizer_openai)
  end

  test "resetting prompt confirms with custom modal and restores default text" do
    visit settings_ai_prompts_path

    all("summary", minimum: 3)[1].click
    editor = find("[data-controller='ai-prompt-editor']")
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
      assert find_button("Reset to default", disabled: true)
    end

    # Re-edit and cancel via dialog close button; ensure prompt is not reset
    within editor do
      fill_in "Prompt", with: "Another custom prompt"
      click_button "Reset to default"
    end

    assert_selector "#confirm-dialog", visible: true
    within "#confirm-dialog" do
      find("[data-action='DS--dialog#close']").click
    end
    assert_no_selector "#confirm-dialog"

    within editor do
      assert_equal "Another custom prompt", find("textarea").value
      assert_text "Using your custom prompt"
    end
  end

  test "displays formatted error and maintains red character counter when prompt exceeds limit" do
    visit settings_ai_prompts_path

    all("summary").first.click
    editor = all("[data-controller='ai-prompt-editor']").first

    within editor do
      find("textarea").fill_in with: "x" * 20_001
      assert_selector "[data-ai-prompt-editor-target='counter'].text-destructive", text: "20,001 / 20,000"
    end

    click_button "Save prompts"
    assert_text "Chat system prompt is too long (maximum is 20,000 characters)"

    # Section with error remains open with red counter
    assert_selector "[data-controller='ai-prompt-editor'] [data-ai-prompt-editor-target='counter'].text-destructive", text: "20,001 / 20,000"
  end
end
