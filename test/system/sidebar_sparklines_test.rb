require "application_system_test_case"

# The sidebar sparkline frames are `loading: "lazy"` and most of them sit
# inside a collapsed account group, so Turbo never fetches them. The timeout
# countdown therefore has to time the request rather than the element
# connecting — otherwise every unexpanded row claims it timed out, ten seconds
# into any page load, without a single request having been made.
class SidebarSparklinesTest < ApplicationSystemTestCase
  SPARKLINE_FRAME = "#sidebar-scroll turbo-frame[data-controller='turbo-frame-timeout']"
  BADGE_TEXT = "Timeout"

  # The group total in the <summary> renders the same chart as the rows inside
  # the disclosure and is on screen from the start, so "a sparkline loaded" has
  # to say which one: the rows are `dom_id(account, :sparkline)`, the total is
  # "#{account_group.key}_sparkline".
  ACCOUNT_SPARKLINE_FRAME = "#{SPARKLINE_FRAME}[id^='sparkline_account_']"
  GROUP_SPARKLINE_FRAME = "#{SPARKLINE_FRAME}[id$='_sparkline']"

  # The shipped window is ten seconds. Outliving it for real would add most of
  # a minute to the system suite for a cosmetic badge, so the frames render
  # with a short one and every wait below is proportional to it.
  SHORT_TIMEOUT_MS = 300

  # A real request may outlive the short window on a busy runner and raise the
  # badge until its response renders over it. The badge checks therefore wait
  # for every fetched frame to finish instead of requiring a response time.
  SETTLE_WAIT_SECONDS = 15

  # Long enough for a sparkline response to arrive inside it, so the render
  # gap test only fails when the countdown outlives a response it already had.
  RENDER_GAP_TIMEOUT_MS = 1500

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

  # Answers sparkline requests with a server error while enabled.
  module FailingSparklines
    mattr_accessor :enabled, default: false

    def sparkline
      return head(:internal_server_error) if FailingSparklines.enabled

      super
    end
  end
  AccountsController.prepend(FailingSparklines)

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

      wait_for_fetched_frames
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

      assert_selector "#{ACCOUNT_SPARKLINE_FRAME}[complete] [data-controller='time-series-chart']", minimum: 1, wait: SETTLE_WAIT_SECONDS

      wait_for_fetched_frames
      wait_out_timeout_window

      assert_no_selector "#{SPARKLINE_FRAME} p", text: BADGE_TEXT, visible: :all
    end
  end

  # The frames above only prove markup arrived. The regression these two
  # tests pin down is one step later: the chart controller refused to draw
  # into the sidebar's 32px-wide containers, so a "complete" frame stayed
  # blank. The trendline is the only <path> the controller draws at these
  # sizes (the empty state uses a dashed <line> + <circle>), so asserting
  # the path proves a real series got rendered, not just an SVG element.
  test "the group total sparkline draws its chart, not just its frame" do
    visit root_path

    assert_selector "#{GROUP_SPARKLINE_FRAME}[complete] [data-controller='time-series-chart'] svg path", minimum: 1
  end

  test "expanding a group draws the account sparklines, not just their frames" do
    visit root_path

    expand_first_group

    assert_selector "#{ACCOUNT_SPARKLINE_FRAME}[complete] [data-controller='time-series-chart'] svg path", minimum: 1
  end

  # Turbo inserts a response and then waits for repaints before it fires
  # turbo:frame-load. Slowing those repaints down after the insertion lets the
  # window expire inside that gap, where a countdown that only stops on
  # frame-load replaces the sparkline that has just been drawn. The window is
  # long enough for the response itself to arrive in time.
  test "a sparkline that has rendered is not replaced by the timeout badge" do
    stub_const(AccountsHelper, :SPARKLINE_FRAME_TIMEOUT_MS, RENDER_GAP_TIMEOUT_MS) do
      visit root_path

      page.execute_script(<<~JS)
        const requestAnimationFrame = window.requestAnimationFrame
        const requestedAt = {}
        window.sparklineResponseTimes = []
        document.addEventListener("turbo:before-fetch-request", (event) => {
          if (event.target.id.startsWith("sparkline_account_")) requestedAt[event.target.id] = performance.now()
        })
        document.addEventListener("turbo:before-fetch-response", (event) => {
          if (event.target.id in requestedAt) window.sparklineResponseTimes.push(performance.now() - requestedAt[event.target.id])
        })
        document.addEventListener("turbo:before-frame-render", (event) => {
          if (!event.target.id.startsWith("sparkline_account_")) return
          const render = event.detail.render
          event.detail.render = (currentElement, newElement) => {
            render(currentElement, newElement)
            window.requestAnimationFrame = (callback) =>
              setTimeout(() => requestAnimationFrame(callback), #{RENDER_GAP_TIMEOUT_MS})
            setTimeout(() => { window.requestAnimationFrame = requestAnimationFrame }, #{RENDER_GAP_TIMEOUT_MS * 4})
          }
        })
      JS

      expand_first_group

      assert_selector ACCOUNT_SPARKLINE_FRAME, minimum: 1
      assert_no_selector "#{ACCOUNT_SPARKLINE_FRAME}:not([complete])", wait: SETTLE_WAIT_SECONDS

      # A response that missed the window would let the badge land before the
      # render and be painted over, which proves nothing about the gap.
      response_times = page.evaluate_script("window.sparklineResponseTimes")
      assert_not_empty response_times
      assert response_times.all? { |ms| ms < RENDER_GAP_TIMEOUT_MS }, "Sparkline responses took #{response_times.map(&:round)} ms"

      assert_no_selector "#{ACCOUNT_SPARKLINE_FRAME} p", text: BADGE_TEXT, visible: :all
      assert_selector "#{ACCOUNT_SPARKLINE_FRAME} [data-controller='time-series-chart'] svg path", minimum: 1
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

  # A response ends the wait only when it succeeds; an error is as much a
  # failed sparkline as a request that never returns.
  test "an error response still raises the timeout badge" do
    with_short_sparkline_timeout do
      visit root_path

      with_failing_sparkline_responses do
        expand_first_group

        assert_selector "#{ACCOUNT_SPARKLINE_FRAME} p", text: BADGE_TEXT, minimum: 1
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

    def with_failing_sparkline_responses
      FailingSparklines.enabled = true
      yield
    ensure
      FailingSparklines.enabled = false
    end

    def expand_first_group
      find("#sidebar-scroll details", match: :first).find("summary").click
    end

    # Turbo marks a frame `busy` only while its request is in flight, so this
    # waits for real responses without treating unfetched lazy frames as late.
    def wait_for_fetched_frames
      assert_no_selector "#{SPARKLINE_FRAME}[busy]", visible: :all, wait: SETTLE_WAIT_SECONDS
    end

    # Sleeping is the assertion here: the badge is an absence, and an absence
    # only means anything once the window it would have fired in has passed.
    def wait_out_timeout_window
      sleep (SHORT_TIMEOUT_MS * 3) / 1000.0
    end
end
