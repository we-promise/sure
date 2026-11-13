require "application_system_test_case"

class ReportsTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    sign_in users(:family_admin)
    # The breakdown table, whose Amount link one test follows, only renders
    # when the month has transactions; fixtures are dated a few days ago, which
    # on the 1st is last month.
    create_transaction(date: Date.current, amount: 50, category: categories(:food_and_drink))
    visit reports_path(period_type: :monthly)

    # The tooltip only shows once the page's controllers are connected, so
    # keys pressed after this reach an installed hotkey.
    find("a[aria-keyshortcuts='ArrowLeft']").hover
    assert_selector "[role='tooltip']", text: "Previous period (←)"

    # Record the links the hotkeys click instead of following them. A hotkey
    # clicks synchronously, so the list is complete when the key returns.
    page.execute_script(<<~JS)
      window.clickedHotkeys = [];
      document.addEventListener("click", (event) => {
        const link = event.target.closest("a[data-hotkey]");
        if (!link) return;
        window.clickedHotkeys.push(link.dataset.hotkey);
        event.preventDefault();
      }, true);
    JS
  end

  test "the arrow keys leave section moves and dialogs alone" do
    find("section[data-sortable-list-id]", match: :first).send_keys(:enter)
    page.send_keys(:arrow_left)
    assert_empty clicked_hotkeys
    page.send_keys(:escape)

    click_link I18n.t("reports.transactions_breakdown.export.google_sheets")
    assert_selector "dialog[open]"
    page.send_keys(:arrow_left)
    assert_empty clicked_hotkeys

    page.send_keys(:escape)
    assert_no_selector "dialog[open]"
    page.send_keys(:arrow_left)
    assert_equal %w[ArrowLeft], clicked_hotkeys
  end

  test "the arrow keys scroll a focused breakdown table instead of changing the period" do
    find("section[data-section-key='transactions_breakdown'] [role='region']", match: :first).send_keys(:arrow_left)
    assert_empty clicked_hotkeys

    find("body").send_keys(:arrow_left)
    assert_equal %w[ArrowLeft], clicked_hotkeys
  end

  test "a held arrow key steps one period" do
    page.execute_script(<<~JS)
      for (const repeat of [false, true, true]) {
        document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowLeft", repeat, bubbles: true }));
      }
    JS

    assert_equal %w[ArrowLeft], clicked_hotkeys
  end

  test "a section moved with the keyboard keeps its new place" do
    first, second = all("section[data-section-key]").first(2).map { |section| section["data-section-key"] }
    record_saved_section_order

    find("section[data-section-key='#{first}']").send_keys(:enter)
    page.send_keys(:arrow_down)
    page.send_keys(:enter)

    assert_selector "html[data-order-saved='200']"
    saved_order = users(:family_admin).reload.reports_section_order
    assert_operator saved_order.index(second), :<, saved_order.index(first)
  end

  test "Enter on a link inside a section follows the link instead of grabbing the section" do
    section = find("section[data-section-key='transactions_breakdown']")
    section.find_link(I18n.t("reports.transactions_breakdown.export.google_sheets")).send_keys(:enter)

    assert_selector "dialog[open]"
    assert_equal "false", section["aria-grabbed"]
  end

  test "following a link while a section is held saves its new place first" do
    keys = all("section[data-section-key]").map { |section| section["data-section-key"] }
    moved = "transactions_breakdown"
    above = keys[keys.index(moved) - 1]

    section = find("section[data-section-key='#{moved}']")
    section.send_keys(:enter)
    page.send_keys(:arrow_up)
    section.find_link(I18n.t("reports.transactions_breakdown.table.amount"), match: :first).send_keys(:enter)

    assert_current_path(/sort_by=amount/)
    saved_order = users(:family_admin).reload.reports_section_order
    assert_operator saved_order.index(moved), :<, saved_order.index(above)
  end

  # The collapse state is saved with the page's CSRF token and nothing is
  # saved without one, and the test environment renders none unless forgery
  # protection is on.
  test "collapsing a section saves it under the reports keys" do
    with_forgery_protection do
      user = users(:family_admin)
      visit reports_path(period_type: :monthly)
      record_saved_section_order

      find("section[data-section-key='transactions_breakdown'] summary").click

      assert_selector "section[data-section-key='transactions_breakdown'] details:not([open])"
      assert_selector "html[data-order-saved='200']"
      assert_equal true, user.reload.preferences.dig("reports_collapsed_sections", "transactions_breakdown")
    end
  end

  test "expanding a collapsed section saves it as open" do
    with_forgery_protection do
      user = users(:family_admin)
      user.update_section_preferences("reports", collapsed: { "transactions_breakdown" => true })
      visit reports_path(period_type: :monthly)
      record_saved_section_order

      find("section[data-section-key='transactions_breakdown'] details:not([open]) > summary").click

      assert_selector "section[data-section-key='transactions_breakdown'] details[open]"
      assert_selector "html[data-order-saved='200']"
      assert_equal false, user.reload.preferences.dig("reports_collapsed_sections", "transactions_breakdown")
    end
  end

  # A <details> rendered open fires `toggle` once it is in the page. Only a
  # change the user makes is saved, so the one collapse is the only request.
  test "rendering the sections saves no collapse state" do
    with_forgery_protection do
      visit reports_path(period_type: :monthly)
      record_saved_section_order
      # A Turbo visit renders the sections again with the request counter
      # already in place.
      page.execute_script("document.body.dataset.before = true; Turbo.visit(window.location.href)")
      assert_no_selector "body[data-before]"

      find("section[data-section-key='transactions_breakdown'] summary").click

      assert_selector "html[data-order-saved='200']"
      assert_equal "1", page.evaluate_script("document.documentElement.dataset.orderRequests")
      assert_equal({ "transactions_breakdown" => true }, users(:family_admin).reload.preferences["reports_collapsed_sections"])
    end
  end

  # The header is a <summary>, its own tab stop after the section's grab stop:
  # Enter there opens and closes the section and leaves reordering alone.
  test "Enter on a section header collapses it instead of grabbing the section" do
    section = find("section[data-section-key='transactions_breakdown']")
    section.find("summary").send_keys(:enter)

    assert_selector "section[data-section-key='transactions_breakdown'] details:not([open])"
    assert_equal "false", section["aria-grabbed"]
  end

  # The whole header is the toggle, and a press-and-hold on it starts a drag.
  # Letting go must not also open or close the section; a plain tap still does.
  test "releasing a press-and-hold leaves the section as it was" do
    section = find("section[data-section-key='transactions_breakdown']")
    summary = section.find("summary")
    page.execute_script(<<~JS, summary)
      window.summaryClicks = 0;
      arguments[0].addEventListener("click", () => window.summaryClicks++);
    JS

    touch(summary, hold: 1.2)
    touch(summary, hold: 0)

    assert_selector "section[data-section-key='transactions_breakdown'] details:not([open])"
    assert_equal 1, page.evaluate_script("window.summaryClicks")
  end

  # Each section's card is a <details>, so a chevron inside it that turns with
  # `group-open:` would follow the open section instead of its own panel.
  test "a closed disclosure inside an open section shows its chevron closed" do
    chevron = find("section[data-section-key='investment_performance'] details[open] details:not([open]) > summary svg", match: :first)

    assert_equal "none", page.evaluate_script("getComputedStyle(arguments[0]).rotate", chevron)
  end

  private
    def clicked_hotkeys
      page.evaluate_script("window.clickedHotkeys")
    end

    def with_forgery_protection
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      yield
    ensure
      ActionController::Base.allow_forgery_protection = original
    end

    # Presses a finger on the element's centre for `hold` seconds, through
    # the browser's touch input, so the browser decides whether a click follows.
    def touch(element, hold:)
      finger = Selenium::WebDriver::Interactions.pointer(:touch, name: "finger")
      page.driver.browser.action(devices: [ finger ])
        .move_to(element.native, device: "finger")
        .pointer_down(:left, device: "finger")
        .pause(device: finger, duration: hold)
        .pointer_up(:left, device: "finger")
        .perform
    end
end
