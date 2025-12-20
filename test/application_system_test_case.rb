require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  setup do
    Capybara.default_max_wait_time = 5
  end

  driven_by :selenium, using: ENV["CI"].present? ? :headless_chrome : ENV.fetch("E2E_BROWSER", :chrome).to_sym, screen_size: [ 1400, 1400 ]

  private

    def sign_in(user)
      visit new_session_path
      within %(form[action='#{sessions_path}']) do
        fill_in "email", with: user.email
        fill_in "password", with: user_password_test
        click_on I18n.t("sessions.new.submit")
      end

      # Trigger Capybara's wait mechanism to avoid timing issues with logins
      find("h1", text: I18n.t("pages.dashboard.welcome", name: user.first_name))
    end

    def login_as(user)
      sign_in(user)
    end

    def sign_out
      find("#user-menu").click
      click_button "Logout"

      # Trigger Capybara's wait mechanism to avoid timing issues with logout
      find("a", text: I18n.t("layouts.auth.sign_in"))
    end

    def within_testid(testid)
      within "[data-testid='#{testid}']" do
        yield
      end
    end
end
