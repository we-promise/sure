require "application_system_test_case"

# The sidebar sparkline frames are `loading: "lazy"` and most of them sit
# inside a collapsed account group, so Turbo never fetches them. The timeout
# countdown therefore has to time the request rather than the element
# connecting — otherwise every unexpanded row claims it timed out, ten seconds
# into any page load, without a single request having been made.
#
# The frames are also data-turbo-permanent and carry a data version in their
# id. A loaded sparkline must survive navigations and morph refreshes while
# its data is unchanged, and must be replaced by a fresh frame once the data
# changes. Idiomorph never removes permanent elements on its own;
# permanent_frame_controller.js releases the stale frame on a morph.
class SidebarSparklinesTest < ApplicationSystemTestCase
  FRAME_SELECTOR = "turbo-frame[id^='tab_'][id*='_sparkline_'][complete]".freeze
  SPARKLINE_FRAME = "#sidebar-scroll turbo-frame[data-controller~='turbo-frame-timeout']"
  BADGE_TEXT = "Timeout"

  # The group total in the <summary> renders the same chart as the rows inside
  # the disclosure and is on screen from the start, so "a sparkline loaded" has
  # to say which one. Both ids carry the placement and the data version (see
  # AccountsHelper#sidebar_sparkline_frame_id); the rows are built from
  # `dom_id(account, :sparkline)`, the total from "#{account_group.key}_sparkline".
  ACCOUNT_SPARKLINE_FRAME = "#{SPARKLINE_FRAME}[id*='_sparkline_account_']"
  GROUP_SPARKLINE_FRAME = "#{SPARKLINE_FRAME}:not([id*='_sparkline_account_'])"

  # The shipped window is ten seconds. Outliving it for real would add most of
  # a minute to the system suite for a cosmetic badge, so the frames render
  # with a short one and every wait below is proportional to it.
  SHORT_TIMEOUT_MS = 300

  # Holds sparkline responses open for as long as a test needs one pending.
  # The wait has to happen inside the server thread, which the test cannot
  # reach, so a process-wide flag stands in for it; clearing the flag releases
  # the request instead of leaving it in flight past the test.
  #
  # It wraps the whole action rather than the series it renders: the browser
  # outlives a single test, so an account whose sparkline an earlier test
  # already fetched answers the conditional GET with a 304 without ever
  # computing one.
  module StalledSparklines
    mattr_accessor :enabled, default: false

    def sparkline
      sleep 0.05 while StalledSparklines.enabled
      super
    end
  end
  AccountsController.prepend(StalledSparklines)

  setup do
    @user = users(:family_admin)
    sign_in @user
  end

  test "a frame that is never fetched keeps its placeholder instead of a timeout badge" do
    with_short_sparkline_timeout do
      visit root_path

      # Nothing is expanded on the dashboard: no account page is active, so
      # every group renders closed and the rows inside it stay off screen.
      assert_no_selector "#sidebar-scroll details[open]"

      # The group's own sparkline sits in the <summary>, so it is on screen and
      # Turbo does fetch it: the page is working, the collapsed rows below are
      # simply never asked for.
      assert_selector "#{GROUP_SPARKLINE_FRAME}[complete]", minimum: 1

      wait_out_timeout_window

      # No badge anywhere in the sidebar, group totals included.
      assert_no_selector "#{SPARKLINE_FRAME} p", text: BADGE_TEXT, visible: :all

      # The rows nobody asked for still hold their loading placeholder, which
      # is an honest description of what they are doing.
      assert_selector "#{ACCOUNT_SPARKLINE_FRAME} .bg-loader", visible: :all, minimum: 1
    end
  end

  test "expanding a group loads its sparklines" do
    with_short_sparkline_timeout do
      visit root_path

      expand_first_group

      assert_selector "#{ACCOUNT_SPARKLINE_FRAME}[complete] [data-controller='time-series-chart']", minimum: 1

      wait_out_timeout_window

      assert_no_selector "#{SPARKLINE_FRAME} p", text: BADGE_TEXT, visible: :all
    end
  end

  test "a request that never comes back still raises the timeout badge" do
    with_short_sparkline_timeout do
      visit root_path

      with_stalled_sparkline_responses do
        expand_first_group

        # On the rows that were stalled, not on a group total that loaded long
        # before the stall was in place.
        assert_selector "#{ACCOUNT_SPARKLINE_FRAME} p", text: BADGE_TEXT, minimum: 1
      end
    end
  end

  test "a loaded sparkline frame is kept while its data is unchanged" do
    with_short_sparkline_timeout do
      visit root_path
      frame_id = mark_loaded_sparkline

      find("a[href='#{transactions_path}']", match: :first).click
      assert_current_path transactions_path
      assert_marked_frame frame_id

      # The kept frame reconnects its timeout controller on the visit, but it
      # is no longer fetching, so no countdown may start again.
      wait_out_timeout_window
      assert_no_selector "#{SPARKLINE_FRAME} p", text: BADGE_TEXT, visible: :all

      refresh_with_morph
      assert_marked_frame frame_id
    end
  end

  test "a morph refresh replaces a sparkline frame whose data changed" do
    visit root_path
    frame_id = mark_loaded_sparkline

    # Any account update moves the sparkline data version, as a completed
    # sync does.
    @user.family.accounts.first.touch

    refresh_with_morph

    assert_no_selector "##{frame_id}", visible: :all
    assert_selector FRAME_SELECTOR, visible: :all
    assert_no_selector "#{FRAME_SELECTOR}[data-test-marker]", visible: :all
  end

  private

    def with_short_sparkline_timeout(&block)
      stub_const(AccountsHelper, :SPARKLINE_FRAME_TIMEOUT_MS, SHORT_TIMEOUT_MS, &block)
    end

    def with_stalled_sparkline_responses
      StalledSparklines.enabled = true
      yield
    ensure
      StalledSparklines.enabled = false
    end

    def expand_first_group
      find("#sidebar-scroll details", match: :first).find("summary").click
    end

    # Sleeping is the assertion here: the badge is an absence, and an absence
    # only means anything once the window it would have fired in has passed.
    def wait_out_timeout_window
      sleep (SHORT_TIMEOUT_MS * 3) / 1000.0
    end

    # Waits for a sidebar sparkline to finish loading and tags that element, so
    # a later check can tell the same DOM node apart from a re-rendered one.
    def mark_loaded_sparkline
      frame = find(FRAME_SELECTOR, match: :first, visible: :all)
      page.execute_script("arguments[0].setAttribute('data-test-marker', 'loaded')", frame)
      frame[:id]
    end

    def assert_marked_frame(frame_id)
      assert_selector "##{frame_id}[complete][data-test-marker='loaded']", visible: :all
    end

    # What a broadcast refresh (turbo_stream_from Current.family) does after a
    # sync completes: reload the current URL, rendered as a morph.
    def refresh_with_morph
      page.execute_script(<<~JS)
        document.documentElement.removeAttribute("data-test-refreshed")
        document.addEventListener("turbo:render", () => {
          document.documentElement.setAttribute("data-test-refreshed", "true")
        }, { once: true })
        Turbo.session.refresh(window.location.href)
      JS
      assert_selector "html[data-test-refreshed='true']", visible: :all
    end
end
