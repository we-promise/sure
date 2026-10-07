require "application_system_test_case"

class ReleaseHighlightsSystemTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: { "last_seen_release_tag" => "v0.7.5" })
    Sure.stubs(:version).returns(Semver.new("0.7.5-hotfix.1"))

    github_provider = mock
    github_provider.stubs(:fetch_release_notes).with("v0.7.5-hotfix.1").returns(
      avatar: nil,
      username: "we-promise",
      name: "v0.7.5-hotfix.1",
      published_at: Date.current,
      body: "<p>Hotfix release notes</p>"
    )
    Provider::Registry.stubs(:get_provider).with(:github).returns(github_provider)
    sign_in @user
  end

  %w[close overlay escape done].each do |method|
    test "#{method} dismissal acknowledges the hotfix across a full reload" do
      find("h1", text: @user.first_name).click
      assert_selector ".release-highlight-popover", text: "Hotfix release notes"

      # driver.js finishes activating its step after the opening animation.
      # Wait for that lifecycle boundary before exercising a dismissal.
      page.document.synchronize do
        active = page.evaluate_script(<<~JS)
          (() => {
            const element = document.querySelector('[data-controller="release-highlight"]');
            const controller = window.Stimulus.getControllerForElementAndIdentifier(element, 'release-highlight');
            return !!controller.driverObj.getState().__activeStep;
          })()
        JS
        raise Capybara::ElementNotFound, "release highlight is still opening" unless active
      end

      case method
      when "close"
        find(".driver-popover-close-btn").click
      when "overlay"
        page.driver.browser.action.move_to_location(10, 10).click.perform
      when "escape"
        page.driver.browser.action.send_keys(:escape).perform
      when "done"
        find(".driver-popover-next-btn").click
      end

      assert_no_selector ".release-highlight-popover"
      # Wait for the asynchronous PATCH to be persisted, not merely for the
      # window-level suppression flag to hide the popup in this document.
      page.document.synchronize do
        raise Capybara::ElementNotFound, "dismissal is not saved yet" unless @user.reload.release_seen?("v0.7.5-hotfix.1")
      end

      refresh
      find("h1", text: @user.first_name).click
      assert_no_selector "[data-controller='release-highlight']", visible: :all
      assert_no_selector ".release-highlight-popover"
    end
  end
end
