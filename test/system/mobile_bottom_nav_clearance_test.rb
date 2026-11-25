require "application_system_test_case"

# On a phone the page scrolls inside #main, under a fixed bottom nav. #main's
# bottom padding keeps the page (full-height pages too) above the nav, and an
# empty ::after spacer reaches down to the padding's end, so the end of the
# page (an account's page numbers and rows-per-page menu) stays reachable
# where Safari leaves a scroll container's bottom padding out of how far it
# scrolls. Chrome doesn't show that bug, so these tests check the spacer is
# there, reaches the padding's end and adds no room of its own.
class MobileBottomNavClearanceTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)
    page.driver.browser.manage.window.resize_to(390, 844)
    # An iPhone's insets where the browser can emulate them (env() is 0 otherwise).
    page.driver.browser.execute_cdp("Emulation.setSafeAreaInsetsOverride", insets: { top: 47, bottom: 34, left: 0, right: 0 }) rescue nil
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.setSafeAreaInsetsOverride", insets: { top: 0, bottom: 0, left: 0, right: 0 }) rescue nil
  end

  test "an account's pagination scrolls clear of the bottom nav" do
    visit_account

    gap = end_of_page
    assert_operator gap["gap"], :>=, 0, "the pagination is under the bottom nav: #{gap.inspect}"
  end

  test "a spacer reaches the end of the bottom padding without adding room" do
    visit_account

    room = end_of_page
    assert_equal room["expected"], room["padding"], "#main's bottom padding isn't 5rem plus the safe area"
    assert_equal room["expected"], room["spacer"], "#main's end spacer isn't as tall as its bottom padding"
    # As tall as the padding and taking nothing from the flow, the spacer's
    # box ends where the padding does.
    assert_equal 0, room["spacerFlowHeight"], "#main's end spacer takes up room in the layout: #{room.inspect}"
    assert_equal room["scrollHeightWithoutSpacer"], room["scrollHeight"], "#main's end spacer adds room beyond the padding: #{room.inspect}"
  end

  # Full-height pages size to #main's content box, which the padding keeps
  # above the nav.
  test "the assistant's message box sits above the bottom nav" do
    with_env_overrides OPENAI_ACCESS_TOKEN: "test-token" do
      users(:family_admin).chats.destroy_all
      visit chats_path

      assert_selector "#main #chat-form textarea"
      rects = page.evaluate_script(<<~JS)
        (() => ({
          form: document.querySelector("#main #chat-form").getBoundingClientRect().bottom,
          nav: document.querySelector("nav[data-viewport-target='bottomNav']").getBoundingClientRect().top
        }))()
      JS
      assert_operator rects["form"], :<=, rects["nav"], "the message box is under the bottom nav: #{rects.inspect}"
    end
  end

  private
    def visit_account
      visit account_path(accounts(:depository))
      assert_selector "#main nav select[name='per_page']", visible: :all
    end

    # Scrolls #main to its end and returns the room between the last
    # pagination control and the top of the bottom nav, with #main's bottom
    # padding, its ::after spacer, how much the spacer adds to the flow, and
    # #main's scroll height with and without the spacer.
    def end_of_page
      page.evaluate_script(<<~JS)
        (() => {
          const main = document.getElementById("main");
          main.scrollTop = main.scrollHeight;
          const probe = document.createElement("div");
          probe.style.height = "calc(5rem + env(safe-area-inset-bottom))";
          document.body.append(probe);
          const expected = getComputedStyle(probe).height;
          const expectedPx = Math.round(probe.getBoundingClientRect().height);
          probe.remove();

          const nav = document.querySelector("nav[data-viewport-target='bottomNav']").getBoundingClientRect();
          const controls = Array.from(main.querySelectorAll("nav select[name='per_page'], nav a, nav select")).map((c) => c.getBoundingClientRect().bottom);
          const bottom = Math.max(...controls);

          // How much the spacer adds to the flow: its height less its negative margin.
          const after = getComputedStyle(main, "::after");
          const spacerFlowHeight = Math.round(parseFloat(after.height) + (parseFloat(after.marginBottom) || 0));

          const scrollHeight = main.scrollHeight;
          const hide = document.createElement("style");
          hide.textContent = "#main::after { display: none !important; }";
          document.head.append(hide);
          const scrollHeightWithoutSpacer = main.scrollHeight;
          hide.remove();

          return {
            gap: Math.floor(nav.top - bottom),
            navTop: nav.top,
            controlsBottom: bottom,
            padding: getComputedStyle(main).paddingBottom,
            spacer: after.height,
            expected,
            expectedPx,
            spacerFlowHeight,
            scrollHeight,
            scrollHeightWithoutSpacer
          };
        })()
      JS
    end
end
