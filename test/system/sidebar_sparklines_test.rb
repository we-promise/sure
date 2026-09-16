require "application_system_test_case"

# The sidebar sparkline frames are `loading: "lazy"` and most of them sit
# inside a collapsed account group, so Turbo never fetches them. The timeout
# countdown therefore has to time the request rather than the element
# connecting — otherwise every unexpanded row claims it timed out, ten seconds
# into any page load, without a single request having been made.
class SidebarSparklinesTest < ApplicationSystemTestCase
  SPARKLINE_FRAME = "#sidebar-scroll turbo-frame[data-controller='turbo-frame-timeout']"
  TIMEOUT_BADGE = "#{SPARKLINE_FRAME} p"
  BADGE_TEXT = "Timeout"

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
      assert_selector "#{SPARKLINE_FRAME}[complete]", minimum: 1

      wait_out_timeout_window

      assert_no_selector TIMEOUT_BADGE, text: BADGE_TEXT, visible: :all

      # The rows nobody asked for still hold their loading placeholder, which
      # is an honest description of what they are doing.
      assert_selector "#{SPARKLINE_FRAME} .bg-loader", visible: :all, minimum: 1
    end
  end

  test "expanding a group loads its sparklines" do
    with_short_sparkline_timeout do
      visit root_path

      expand_first_group

      assert_selector "#{SPARKLINE_FRAME}[complete] [data-controller='time-series-chart']", minimum: 1

      wait_out_timeout_window

      assert_no_selector TIMEOUT_BADGE, text: BADGE_TEXT, visible: :all
    end
  end

  test "a request that never comes back still raises the timeout badge" do
    with_short_sparkline_timeout do
      visit root_path

      with_stalled_sparkline_responses do
        expand_first_group

        assert_selector TIMEOUT_BADGE, text: BADGE_TEXT, minimum: 1
      end
    end
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
end
