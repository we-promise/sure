require "test_helper"
require "socket"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  DEFAULT_VIEWPORT_WIDTH = 1400
  DEFAULT_VIEWPORT_HEIGHT = 1400

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

    reset_viewport
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

  def teardown
    reset_viewport
    super
  end

  private

    def reset_viewport
      page.current_window.resize_to(DEFAULT_VIEWPORT_WIDTH, DEFAULT_VIEWPORT_HEIGHT) if page&.current_window
    end

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

    # Interact with DS::Select custom dropdown components.
    # DS::Select renders as a button + listbox — not a native <select> — so
    # Capybara's built-in `select(value, from:)` does not work with it.
    def select_ds(label_text, record)
      field_label = find("label", exact_text: label_text)
      container = field_label.ancestor("div.relative")
      container.find("button").click
      if container.has_selector?("input[type='search']", visible: true)
        container.find("input[type='search']", visible: true).set(record.name)
      end
      listbox = container.find("[role='listbox']", visible: true)
      listbox.find("[role='option'][data-value='#{record.id}']", visible: true).click
    end
end
