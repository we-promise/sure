require "application_system_test_case"

# On a phone the page scrolls inside #main, under a fixed bottom nav; #main's
# bottom padding keeps the end of the page (an account's page numbers and
# rows-per-page menu) clear of it, including when the page runs below the
# visible screen.
class MobileBottomNavClearanceTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)
    page.driver.browser.manage.window.resize_to(390, 844)
    # An iPhone's insets where the browser can emulate them (env() is 0 otherwise).
    page.driver.browser.execute_cdp("Emulation.setSafeAreaInsetsOverride", insets: { top: 47, bottom: 34, left: 0, right: 0 }) rescue nil
    visit account_path(accounts(:depository))
    assert_selector "#main nav select[name='per_page']", visible: :all
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.setSafeAreaInsetsOverride", insets: { top: 0, bottom: 0, left: 0, right: 0 }) rescue nil
  end

  test "an account's pagination clears the bottom nav when the page runs below the screen" do
    # The page's height as an installed web app on iOS could take it: taller
    # than the screen it's shown on.
    page.execute_script(%(document.documentElement.style.setProperty("--app-height", `${window.innerHeight + 150}px`)))

    gap = nil
    page.document.synchronize(5) do
      gap = pagination_gap
      raise Capybara::ExpectationNotMet, "the pagination is under the bottom nav: #{gap.inspect}" if gap["gap"] < 0
    end
    assert_operator gap["gap"], :>=, 0, "the pagination is under the bottom nav: #{gap.inspect}"
  end

  # A morph refresh (the sync toast's, or a broadcast) reconciles the page's
  # elements with the server's markup, which carries none of the measured
  # values.
  test "the pagination still clears the bottom nav after a morph refresh" do
    page.execute_script(%(document.documentElement.style.setProperty("--app-height", `${window.innerHeight + 150}px`)))
    page.document.synchronize(5) do
      raise Capybara::ExpectationNotMet, "the pagination is under the bottom nav" if pagination_gap["gap"] < 0
    end

    page.execute_script(<<~JS)
      window.__morphed = false;
      document.addEventListener("turbo:morph", () => { window.__morphed = true; }, { once: true });
      Turbo.session.refresh(location.href);
    JS
    page.document.synchronize(10) do
      raise Capybara::ExpectationNotMet, "no morph refresh yet" unless page.evaluate_script("window.__morphed")
    end
    assert_selector "#main nav select[name='per_page']", visible: :all

    gap = pagination_gap
    assert_operator gap["gap"], :>=, 0, "the pagination is under the bottom nav after a morph refresh: #{gap.inspect}"
  end

  test "where the page ends at the screen the bottom padding is as before" do
    padding = page.evaluate_script(<<~JS)
      (() => {
        const probe = document.createElement("div");
        probe.style.paddingBottom = "calc(5rem + env(safe-area-inset-bottom))";
        document.body.append(probe);
        const expected = getComputedStyle(probe).paddingBottom;
        probe.remove();
        return { expected, actual: getComputedStyle(document.getElementById("main")).paddingBottom };
      })()
    JS
    assert_equal padding["expected"], padding["actual"]
    assert_operator pagination_gap["gap"], :>=, 0
  end

  private
    # Scrolls #main to its end and returns the room between the last
    # pagination control and the top of the bottom nav.
    def pagination_gap
      page.evaluate_script(<<~JS)
        (() => {
          const main = document.getElementById("main");
          main.scrollTop = main.scrollHeight;
          const nav = document.querySelector("nav[data-viewport-target='bottomNav']").getBoundingClientRect();
          const controls = Array.from(main.querySelectorAll("nav select[name='per_page'], nav a, nav select")).map((c) => c.getBoundingClientRect().bottom);
          const bottom = Math.max(...controls);
          return { gap: Math.floor(nav.top - bottom), navTop: nav.top, controlsBottom: bottom, padding: getComputedStyle(main).paddingBottom };
        })()
      JS
    end
end
