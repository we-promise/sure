require "application_system_test_case"

class PeriodPickerBackTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)
  end

  test "Back after a pick shows the previous period" do
    account = accounts(:depository)
    visit account_path(account)
    assert_selector "main h2", text: account.name

    pick_period "90D"
    page.go_back

    assert_selector "#{period_button("30D")}[aria-expanded='false']"
    assert_current_path account_path(account)
  end

  test "Back after a tab switch and a pick shows the tab and the previous period" do
    account = accounts(:investment)
    visit account_path(account)
    find("[role='tab']", text: "Holdings").click
    assert_current_path account_path(account, tab: "holdings")

    pick_period "90D"
    page.go_back

    assert_selector "#{period_button("30D")}[aria-expanded='false']"
    assert_selector "[role='tab'][aria-selected='true']", text: "Holdings"
    assert_current_path account_path(account, tab: "holdings")
  end

  test "Back from a page opened after a pick shows the pick, then the previous period" do
    pick_period "90D"
    click_link "Transactions"
    assert_selector "main h1", text: "Transactions"

    page.go_back
    assert_selector period_button("90D")

    page.go_back
    assert_selector "#{period_button("30D")}[aria-expanded='false']"
    assert_current_path root_path
  end

  test "Back after leaving before a pick loads stays on the page left for" do
    execute_script(<<~JS)
      document.addEventListener("turbo:before-fetch-request", function hold(event) {
        if (event.target.id !== "dashboard_sections") return;
        document.removeEventListener("turbo:before-fetch-request", hold);
        event.preventDefault();
        window.releasePick = event.detail.resume;
      });
    JS
    find(any_period_button).click
    click_link "90D"
    click_link "Transactions"
    assert_selector "main h1", text: "Transactions"

    # Turbo 8.0.13 still renders the frame the page left behind, then pushes
    # its URL and promotes it to a visit.
    wait_for_turbo_load { execute_script("window.releasePick()") }
    page.go_back

    assert_not has_selector?(any_period_button, wait: 1)
    assert_current_path transactions_path
  end

  private
    def period_button(label)
      "button[aria-label='#{I18n.t("UI.period_picker.aria_label", period: label)}']"
    end

    def any_period_button
      "button[aria-label^='#{I18n.t("UI.period_picker.aria_label", period: "")}']"
    end

    def pick_period(label)
      find(any_period_button).click
      wait_for_turbo_load { click_link label }
      assert_selector period_button(label)
    end

    # A pick renders its frame, then Turbo promotes it to a page visit that
    # pushes the new URL. Leaving before that visit's turbo:load cancels it,
    # which no person clicks fast enough to do.
    def wait_for_turbo_load
      execute_script("document.addEventListener('turbo:load', () => document.documentElement.dataset.turboLoaded = '', { once: true })")
      yield
      assert_selector "html[data-turbo-loaded]", visible: :all
      execute_script("delete document.documentElement.dataset.turboLoaded")
    end
end
