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

  test "shadow results say there is no data rather than showing zero agreement" do
    # An empty table or a bare 0% reads as "the providers never agree", which is
    # the opposite of "nothing has been sampled yet".
    set_preview_features(true)

    visit settings_hosting_path

    assert_text "No comparisons recorded yet"
    assert_no_text "% agreement across"
  end

  test "shadow results summarise recorded comparisons" do
    set_preview_features(true)
    @family.categorization_comparisons.create!(
      applied_provider: "openai", applied_category_name: "Groceries",
      shadow_provider: "jev", shadow_category_name: "Restaurants & Bars",
      shadow_confidence: 0.52, agreed: false
    )
    @family.categorization_comparisons.create!(
      applied_provider: "openai", applied_category_name: "Coffee",
      shadow_provider: "jev", shadow_category_name: "Coffee",
      shadow_confidence: 0.97, agreed: true
    )

    visit settings_hosting_path

    assert_text "50.0% agreement across 2 sampled transactions"
    assert_text "openai chose Groceries; jev chose Restaurants & Bars"
    assert_text "confidence 0.52"
  end

  test "the tuning controls state what they cost" do
    set_preview_features(true)

    visit settings_hosting_path

    # Shadow mode doubles spend; that must be on the page, not buried in docs.
    assert_text "doubles the API spend"
    assert_field "family[categorization_shadow_rate]"

    # The threshold only means something for a provider that reports confidence.
    assert_no_field "family[categorization_confidence_threshold]"
    select "Jev (TypeSafe)", from: "Categorization provider"
    assert_field "family[categorization_confidence_threshold]"
    assert_text "left uncategorized, so a later run can try again"
  end

  test "credentials appear inside the panel only once Jev is selected" do
    # The key field used to live in a separate panel below, so an operator could
    # enter a key and have nothing happen. Selecting the provider and giving it
    # a key are one task and belong in one place.
    set_preview_features(true)

    visit settings_hosting_path

    # Matched by field name, not label: the Anthropic panel on the same page
    # also labels its token "API Key".
    assert_no_field "setting[jev_api_key]"

    select "Jev (TypeSafe)", from: "Categorization provider"

    assert_field "setting[jev_api_key]"
    assert_field "setting[jev_endpoint]"
    assert_field "setting[jev_model]"
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
