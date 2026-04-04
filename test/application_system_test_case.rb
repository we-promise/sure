require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  setup do
    Capybara.default_max_wait_time = 5
  end

  def select_custom(label_text, value)
    normalized = label_text.gsub("*", "").strip
    label = find("label", text: /#{Regexp.escape(normalized)}/i)
    field = label.find(:xpath, "./ancestor::*[contains(@class, 'form-field')][1]")
    field.find("[data-select-target='button']").click

    find("[role='option']", text: value).click
  end

  def assert_custom_selected(label_text, value)
    normalized = label_text.gsub("*", "").strip
    label = find("label", text: /#{Regexp.escape(normalized)}/i)
    field = label.find(:xpath, "./ancestor::*[contains(@class, 'form-field')][1]")
    button = field.find("[data-select-target='button']")
    print button.text value
    assert_includes button.text, value
  end

  driven_by :selenium, using: ENV["CI"].present? ? :headless_chrome : ENV.fetch("E2E_BROWSER", :chrome).to_sym, screen_size: [ 1400, 1400 ]

  private

    def sign_in(user)
      visit new_session_path
      within %(form[action='#{sessions_path}']) do
        fill_in "Email", with: user.email
        fill_in "Password", with: user_password_test
        click_on "Log in"
      end

      # Trigger Capybara's wait mechanism to avoid timing issues with logins
      find("h1", text: "Welcome back, #{user.first_name}")
    end

    def login_as(user)
      sign_in(user)
    end

    def sign_out
      find("#user-menu").click
      click_button "Logout"

      # Trigger Capybara's wait mechanism to avoid timing issues with logout
      find("a", text: "Sign in")
    end

    def within_testid(testid)
      within "[data-testid='#{testid}']" do
        yield
      end
    end
end
