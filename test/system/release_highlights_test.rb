require "application_system_test_case"

class ReleaseHighlightsSystemTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: { "last_seen_release_tag" => "v0.7.5" })
    Sure.stubs(:version).returns(Semver.new("0.7.5-hotfix.1"))

    Provider::Github.any_instance.stubs(:fetch_release_notes).with("v0.7.5-hotfix.1").returns(
      avatar: nil,
      username: "we-promise",
      name: "v0.7.5-hotfix.1",
      published_at: Date.current,
      body: "<p>Hotfix release notes</p>"
    )
    sign_in @user
  end

  %w[close overlay escape done].each do |method|
    test "#{method} dismissal acknowledges the hotfix across a full reload" do
      find("h1", text: @user.first_name).click
      assert_selector "dialog[open]", text: "Hotfix release notes"

      case method
      when "close"
        within("dialog[open]") { click_on I18n.t("ds.dialog.close") }
      when "overlay"
        page.driver.browser.action.move_to_location(10, 10).click.perform
      when "escape"
        page.driver.browser.action.send_keys(:escape).perform
      when "done"
        within("dialog[open]") { click_on I18n.t("layouts.application.release_highlight.done") }
      end

      assert_no_selector "dialog[open]"
      # Wait for the asynchronous PATCH to be persisted, not merely for the
      # window-level suppression flag to hide the popup in this document.
      page.document.synchronize do
        raise Capybara::ElementNotFound, "dismissal is not saved yet" unless @user.reload.release_seen?("v0.7.5-hotfix.1")
      end

      refresh
      find("h1", text: @user.first_name).click
      assert_no_selector "[data-controller='release-highlight']", visible: :all
      assert_no_selector "dialog[open]"
    end
  end

  # The first click on a page arms the popup, and it is often the click that
  # opens a drawer. A driver.js popover opened under the drawer, a modal
  # <dialog> above anything else on the page, and its pointer-events: none
  # took every click on the drawer with it, Close included.
  test "a drawer opened by the first click stays usable and the popup waits for it" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    due = 6.days.ago.to_date
    bill = @user.family.recurring_transactions.create!(
      name: "City Water", account: accounts(:depository), amount: 80, currency: "USD",
      expected_day_of_month: due.day, last_occurrence_date: 2.months.ago.to_date,
      next_expected_date: due, status: "active"
    )

    visit bills_url
    first("a[data-turbo-frame='drawer'][href^='#{bill_path(bill)}']").click

    assert_selector "dialog[open]", text: "City Water"
    assert_no_selector "dialog[open]", text: "Hotfix release notes"
    within("dialog[open]", text: "City Water") { click_on I18n.t("ds.dialog.close") }
    assert_no_selector "dialog[open]", text: "City Water"

    within("dialog[open]", text: "Hotfix release notes") do
      click_on I18n.t("layouts.application.release_highlight.done")
    end
    assert_no_selector "dialog[open]"
  end

  # Turbo marks a frame busy while it loads. When the notes come back first,
  # the popup would open and the drawer would land on top of it.
  test "the popup waits for a drawer that is still loading" do
    page.execute_script("document.getElementById('drawer').setAttribute('busy', '')")
    find("h1", text: @user.first_name).click

    page.document.synchronize do
      waiting = page.evaluate_script(<<~JS)
        (() => {
          const element = document.querySelector('[data-controller="release-highlight"]');
          return !!window.Stimulus.getControllerForElementAndIdentifier(element, "release-highlight").uncoveredPoll;
        })()
      JS
      raise Capybara::ElementNotFound, "the popup is not waiting yet" unless waiting
    end
    assert_no_selector "dialog[open]"

    page.execute_script("document.getElementById('drawer').removeAttribute('busy')")
    assert_selector "dialog[open]", text: "Hotfix release notes"
  end
end
