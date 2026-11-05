require "application_system_test_case"

class PortfoliosTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
  end

  # The collapse control sends the page's CSRF token and saves nothing without
  # one, and the test environment renders none unless forgery protection is on.
  test "collapsing a section saves it under the portfolio keys, not the Reports ones" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    visit portfolio_path

    find("section[data-section-key='accounts'] button[data-reports-section-target='button']").click

    assert_selector "section[data-section-key='accounts'] button[aria-expanded='false']"
    assert wait_for { @user.reload.preferences.dig("portfolio_collapsed_sections", "accounts") == true },
      "the collapse was not saved under portfolio_collapsed_sections"
    assert_nil @user.preferences["reports_collapsed_sections"]
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  private
    def wait_for(timeout: Capybara.default_max_wait_time)
      deadline = Time.current + timeout
      until (result = yield)
        break if Time.current > deadline
        sleep 0.1
      end
      result
    end
end
