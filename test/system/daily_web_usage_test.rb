require "application_system_test_case"

class DailyWebUsageSystemTest < ApplicationSystemTestCase
  setup do
    # Enable only the tracker markup. The real SDK remains disabled in test;
    # every capture below goes to an offline fake.
    ApplicationController.view_context_class.any_instance.stubs(:daily_web_usage_enabled?).returns(true)
    @user = users(:family_admin)
    sign_in @user
    visit settings_preferences_path
    wait_for_tracker
    page.execute_script("localStorage.removeItem(arguments[0]); sessionStorage.removeItem('daily-usage-test-events');", storage_key(@user))
  end

  test "web visits capture once across Turbo navigation, preference changes and full reloads" do
    install_fake
    assert_event_count 1
    assert_equal false, captured_events.first.dig("properties", "preview_features_enabled")

    page.execute_script(<<~JS)
      document.dispatchEvent(new Event('posthog:ready'));
      document.dispatchEvent(new Event('visibilitychange'));
      window.dispatchEvent(new PageTransitionEvent('pageshow'));
    JS
    flush_tracking
    assert_event_count 1

    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    page.execute_script("Turbo.visit(arguments[0])", root_path)
    assert_current_path root_path
    wait_for_tracker
    assert_selector "[data-daily-web-usage-preview-features-enabled-value='true']", visible: :all
    flush_tracking
    assert_event_count 1

    page.refresh
    wait_for_tracker
    install_fake
    flush_tracking
    assert_event_count 1
  end

  test "logout and another account do not share the daily marker" do
    install_fake
    assert_event_count 1
    click_button "Logout"
    assert_current_path new_session_path
    assert_no_selector "[data-controller='daily-web-usage']", visible: :all

    other = users(:family_member)
    other.update!(preferences: other.preferences.merge("preview_features_enabled" => true))
    sign_in other
    wait_for_tracker
    install_fake
    assert_event_count 2
    assert_equal [ false, true ], captured_events.map { |event| event.dig("properties", "preview_features_enabled") }
    assert page.evaluate_script("localStorage.getItem(arguments[0]) !== null", storage_key(@user))
    assert page.evaluate_script("localStorage.getItem(arguments[0]) !== null", storage_key(other))
  end

  test "hidden pages, Turbo previews and cached controllers wait for a real visible opening" do
    install_fake(notify: false)
    page.execute_script(<<~JS)
      Object.defineProperty(document, 'hidden', {configurable: true, get: () => true});
      document.dispatchEvent(new Event('posthog:ready'));
    JS
    flush_tracking
    assert_event_count 0

    page.execute_script(<<~JS)
      delete document.hidden;
      document.documentElement.setAttribute('data-turbo-preview', '');
      document.dispatchEvent(new Event('visibilitychange'));
    JS
    flush_tracking
    assert_event_count 0

    page.execute_script(<<~JS)
      document.documentElement.removeAttribute('data-turbo-preview');
      document.dispatchEvent(new Event('turbo:before-cache'));
      document.dispatchEvent(new Event('posthog:ready'));
    JS
    flush_tracking
    assert_event_count 0

    page.execute_script("window.dispatchEvent(new PageTransitionEvent('pageshow'))")
    assert_event_count 1
  end

  test "a delayed browser lock cannot capture after its controller disconnects" do
    install_fake(notify: false)
    page.execute_script(<<~JS)
      Object.defineProperty(navigator, 'locks', {configurable: true, value: {
        request: (_name, callback) => { window.delayedDailyCapture = callback; return Promise.resolve(); }
      }});
      document.dispatchEvent(new Event('posthog:ready'));
      document.querySelector('[data-controller="daily-web-usage"]').remove();
    JS
    page.execute_script(<<~JS)
      window.delayedDailyCapture();
      delete navigator.locks;
    JS
    assert_event_count 0
  end

  private
    def storage_key(user)
      "sure:daily-web-usage:#{user.id}"
    end

    def wait_for_tracker
      assert_selector "body" do
        page.evaluate_script(<<~JS)
          !!window.Stimulus?.getControllerForElementAndIdentifier(
            document.querySelector('[data-controller="daily-web-usage"]'), 'daily-web-usage'
          )
        JS
      end
    end

    def install_fake(notify: true)
      page.execute_script(<<~JS)
        window.posthog = {
          __loaded: true,
          has_opted_out_capturing: () => false,
          capture: (event, properties) => {
            if (event === 'web_app_opened_daily') {
              const events = JSON.parse(sessionStorage.getItem('daily-usage-test-events') || '[]');
              events.push({event, properties});
              sessionStorage.setItem('daily-usage-test-events', JSON.stringify(events));
            }
            return {};
          }
        };
        if (#{notify}) document.dispatchEvent(new Event('posthog:ready'));
      JS
    end

    def captured_events
      page.evaluate_script("JSON.parse(sessionStorage.getItem('daily-usage-test-events') || '[]')")
    end

    def assert_event_count(count)
      assert_selector("body") { captured_events.length == count }
    end

    def flush_tracking
      page.driver.browser.execute_async_script(<<~JS, storage_key(@user))
        const done = arguments[arguments.length - 1];
        const key = arguments[0];
        if (navigator.locks?.request) navigator.locks.request(key, () => {}).then(done);
        else done();
      JS
    end
end
