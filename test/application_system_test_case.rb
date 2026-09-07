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
    requested_browser = ENV["E2E_BROWSER"].presence&.to_sym
    local_browser = case requested_browser
    when :headless_chrome then :chrome
    when :headless_firefox then :firefox
    else requested_browser || :chrome
    end

    headless = ENV["CI"].present? || requested_browser.in?([ :headless_chrome, :headless_firefox ]) || ENV["DISPLAY"].blank?

    Capybara.register_driver :selenium_local_chrome do |app|
      options = case local_browser
      when :firefox
        Selenium::WebDriver::Firefox::Options.new.tap do |firefox_options|
          firefox_options.add_argument("--width=1400")
          firefox_options.add_argument("--height=1400")
          firefox_options.add_argument("-headless") if headless
        end
      else
        Selenium::WebDriver::Chrome::Options.new.tap do |chrome_options|
          chrome_options.add_argument("--window-size=1400,1400")
          chrome_options.add_argument("--headless=new") if headless
          chrome_options.add_argument("--no-sandbox")
          chrome_options.add_argument("--disable-dev-shm-usage")
          chrome_options.binary = ENV["CHROME_BIN"] if ENV["CHROME_BIN"].present?
        end
      end

      Capybara::Selenium::Driver.new(
        app,
        browser: local_browser,
        options: options
      )
    end

    driven_by :selenium_local_chrome, screen_size: [ 1400, 1400 ]
  end

  # Capybara sees the *outgoing* body while a Turbo visit is still in flight,
  # so assertions pass — and clicks land — on a page that is about to be
  # replaced. That is invisible when the destination differs from the current
  # page, and silent when it does not: work done on the outgoing body (an
  # opened `#modal` dialog, say) is discarded by the render with no error.
  #
  # Waiting for the body to be replaced is not enough on its own. A visit to a
  # URL Turbo has cached renders TWICE — the cached snapshot first, then the
  # fresh response — and each render replaces the body, so a "the old body is
  # gone" check clears on the preview and hands the test a page Turbo is still
  # about to replace. `turbo:load` fires once per visit, after the final
  # render, so that is what we wait for; the outgoing-body stamp stays as the
  # guarantee that a render happened at all rather than the flag being left
  # over from an earlier navigation.
  def click_link_and_wait_for_render(locator, **options)
    page.execute_script(<<~JAVASCRIPT)
      document.body.dataset.preVisitBody = "true"
      document.addEventListener(
        "turbo:load",
        () => { document.body.dataset.turboVisitComplete = "true" },
        { once: true }
      )
    JAVASCRIPT

    click_link(locator, **options)

    assert_selector "body[data-turbo-visit-complete]", visible: :all
    assert_no_selector "body[data-pre-visit-body]", visible: :all
    # Turbo stamps the root element while a cached preview is on screen, so
    # this fails loudly if the waits above ever start clearing on a preview.
    assert_no_selector "html[data-turbo-preview]", visible: :all
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
