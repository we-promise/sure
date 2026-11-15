require "application_system_test_case"

class PortfoliosTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
  end

  # The collapse state is saved with the page's CSRF token and nothing is
  # saved without one, and the test environment renders none unless forgery
  # protection is on.
  test "collapsing a section saves it under the portfolio keys, not the Reports ones" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    visit portfolio_path
    record_saved_section_order

    find("section[data-section-key='accounts'] summary").click

    assert_selector "section[data-section-key='accounts'] details:not([open])"
    assert_selector "html[data-order-saved='200']"
    assert_equal true, @user.reload.preferences.dig("portfolio_collapsed_sections", "accounts")
    assert_nil @user.preferences["reports_collapsed_sections"]
  ensure
    ActionController::Base.allow_forgery_protection = original
  end
end
