require "application_system_test_case"

class Settings::CategorizationProviderTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    # The settings page is guarded by self_hosted?, and the panel itself is
    # behind the preview gate.
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
  end

  teardown do
    @family.update!(categorization_provider: "llm")
  end

  test "the panel is hidden until a user opts into preview features" do
    set_preview_features(false)

    visit settings_hosting_path

    assert_no_text "Transaction Categorization"
  end

  test "an opted-in user switches the family onto Jev and back" do
    set_preview_features(true)

    visit settings_hosting_path

    assert_text "Transaction Categorization"
    assert_equal "llm", @family.reload.categorization_provider

    # The select auto-submits on change, so choosing an option is the whole
    # interaction — there is no save button to press.
    select "Jev (TypeSafe)", from: "Categorization provider"
    assert_text "Data sharing"
    assert_equal "jev", @family.reload.categorization_provider

    select "AI provider (OpenAI or Anthropic)", from: "Categorization provider"
    assert_no_text "Data sharing"
    assert_equal "llm", @family.reload.categorization_provider
  end

  test "selecting Jev without an API key warns that categorization will not switch" do
    set_preview_features(true)
    Provider::Jev.stubs(:configured?).returns(false)

    visit settings_hosting_path
    select "Jev (TypeSafe)", from: "Categorization provider"

    assert_text "Jev is selected but has no API key configured"
  end

  private
    def set_preview_features(enabled)
      @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => enabled))
    end
end
