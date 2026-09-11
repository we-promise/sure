require "application_system_test_case"

# Anchored feature highlights: the dashboard offers a driver.js popover
# spotlighting a new feature's nav entry (Bills in v0.7.5), once per
# account, and only to users who can actually use the feature.
class FeatureHighlightTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    Sure.stubs(:version).returns(Semver.new("0.7.5"))
  end

  test "preview user gets the Bills spotlight once, and dismissal persists" do
    # Release popup already acknowledged so it does not compete here.
    @user.update!(preferences: {
      "preview_features_enabled" => true,
      "last_seen_release_tag" => Sure.version.to_release_tag
    })

    visit root_path

    # The popover waits for the first real interaction.
    assert_no_selector ".driver-popover"
    find("main h1").click

    assert_selector ".driver-popover", text: "Meet Bills"
    # The spotlight is anchored on the Bills nav entry.
    assert_selector "a.driver-active-element[data-feature-highlight='bills']"

    click_on "Got it"

    assert_no_selector ".driver-popover"
    sleep 1
    dump_browser_console
    assert_equal "v0.7.5-alpha.1", wait_for_feature_seen("bills")

    visit root_path
    find("main h1").click

    assert_no_selector ".driver-popover"
  end

  test "Bills popover follows the release popup instead of competing with it" do
    @user.update!(preferences: { "preview_features_enabled" => true })

    release_notes = {
      avatar: nil,
      username: "we-promise",
      name: Sure.version.to_release_tag,
      published_at: Date.current,
      body: "<p>Shiny new things</p>"
    }
    github_provider = mock
    github_provider.stubs(:fetch_release_notes).returns(release_notes)
    Provider::Registry.stubs(:get_provider).with(:github).returns(github_provider)

    visit root_path
    find("main h1").click

    # The release popup goes first...
    assert_selector ".driver-popover", text: "What's new"
    assert_no_selector ".driver-popover", text: "Meet Bills"

    click_on "Got it"

    # ...and the Bills spotlight follows on the same page, no reload.
    assert_selector ".driver-popover", text: "Meet Bills"
    assert_selector "a.driver-active-element[data-feature-highlight='bills']"

    click_on "Got it"
    assert_no_selector ".driver-popover"

    assert_equal Sure.version.to_release_tag, wait_for_release_seen
    assert_equal "v0.7.5-alpha.1", wait_for_feature_seen("bills")
  end

  test "users without preview features never see the Bills spotlight" do
    @user.update!(preferences: {
      "last_seen_release_tag" => Sure.version.to_release_tag
    })

    visit root_path
    find("main h1").click

    assert_no_selector ".driver-popover"
  end

  private

    def dump_browser_console
      logs = page.driver.browser.logs.get(:browser)
      puts "BROWSER CONSOLE: #{logs.map { |l| "#{l.level}: #{l.message}" }.join(" | ")}"
    rescue => e
      puts "BROWSER CONSOLE unavailable: #{e.class}"
    end

    # Dismissal persists via an async PATCH; poll briefly instead of racing it.
    def wait_for_feature_seen(key)
      wait_for_value { @user.reload.seen_feature_highlights[key] }
    end

    def wait_for_release_seen
      wait_for_value { @user.reload.last_seen_release_tag }
    end

    def wait_for_value
      Timeout.timeout(Capybara.default_max_wait_time) do
        loop do
          value = yield
          return value if value.present?
          sleep 0.1
        end
      end
    end
end
