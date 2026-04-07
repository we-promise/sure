require "test_helper"
require "socket"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  setup do
    Capybara.default_max_wait_time = 5

    if ENV["SELENIUM_REMOTE_URL"].present?
      server_port = ENV.fetch("CAPYBARA_SERVER_PORT", 30_000 + (Process.pid % 1000)).to_i
      app_host = ENV["CAPYBARA_APP_HOST"].presence || IPSocket.getaddress(Socket.gethostname)

      Capybara.server_host = "0.0.0.0"
      Capybara.server_port = server_port
      Capybara.always_include_port = true
      Capybara.app_host = "http://#{app_host}:#{server_port}"
    end
  end

  if ENV["SELENIUM_REMOTE_URL"].present?
    Capybara.register_driver :selenium_remote_chrome do |app|
      options = Selenium::WebDriver::Chrome::Options.new
      options.add_argument("--window-size=1400,1400")

      Capybara::Selenium::Driver.new(
        app,
        browser: :remote,
        url: ENV["SELENIUM_REMOTE_URL"],
        capabilities: options
      )
    end

    driven_by :selenium_remote_chrome, screen_size: [ 1400, 1400 ]
  else
    driven_by :selenium, using: ENV["CI"].present? ? :headless_chrome : ENV.fetch("E2E_BROWSER", :chrome).to_sym, screen_size: [ 1400, 1400 ]
  end

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
