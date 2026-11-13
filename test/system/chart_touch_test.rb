require "application_system_test_case"

# On a touchscreen a chart has no hover and no mouse drag: a finger sliding
# along it moves the tooltip (scrubbing), and a long press followed by a slide
# selects a date range. Vertical swipes must still scroll the page. The
# gestures are real touch input (Chrome DevTools Input.dispatchTouchEvent), so
# the browser applies touch-action and fires pointer and emulated mouse events
# as it does on a phone.
class ChartTouchTest < ApplicationSystemTestCase
  CHART = "#netWorthChart".freeze

  setup do
    # Real touch input comes through Chrome DevTools, which other drivers lack.
    skip "needs Chrome DevTools touch input" unless page.driver.browser.respond_to?(:execute_cdp)
    sign_in users(:family_admin)
    assert_selector "#{CHART} .drag-select-brush .overlay", visible: :all
    # Touch input lands on whatever is at the point, so the chart must be on screen.
    page.execute_script(%(document.querySelector("#{CHART}").scrollIntoView({ block: "center" })))
    # WebDriver mouse actions from an earlier test can keep DevTools touch
    # input from arriving (seen with Chrome 156): start from a clean state.
    page.driver.browser.action.release_actions
  end

  test "a finger sliding along the chart moves the tooltip with it, and it stays until a touch elsewhere" do
    from = chart_point(0.2)
    nudged = [ from[0] + 30, from[1] ]
    to = chart_point(0.8)

    # Moving off the first point straight away: a finger resting longer
    # than the long press starts a selection instead (the next test).
    touch("touchStart", from)
    touch("touchMove", nudged)
    first_date = tooltip_date
    assert tooltip_visible?, "a touch shows the tooltip"

    slide(nudged, to)
    # The browser may deliver the last move with the next frame.
    page.document.synchronize(5) do
      off_by = (to[0] - chart_box["left"] - guideline_x).abs
      raise Capybara::ExpectationNotMet, "the guideline is #{off_by.round}px from the finger" if off_by > point_spacing
    end
    assert_not_equal first_date, tooltip_date, "the tooltip did not follow the finger"

    touch("touchEnd")
    assert tooltip_visible?, "lifting the finger keeps the tooltip on the last point"
    assert_equal "/", URI.parse(page.current_url).path

    header = page.evaluate_script(%(document.querySelector("#{CHART}").getBoundingClientRect().top)) - 40
    touch("touchStart", [ 20, header ])
    touch("touchEnd")
    assert_not tooltip_visible?, "a touch elsewhere hides the tooltip"
  end

  test "a long press then a slide selects a date range" do
    from = chart_point(0.3)
    to = chart_point(0.7)

    touch("touchStart", from)
    sleep 0.7
    assert_selector "#{CHART} .touch-selection", visible: :all
    slide(from, to)
    selection_width = page.evaluate_script(%(Number(document.querySelector("#{CHART} .touch-selection").getAttribute("width"))))
    assert_in_delta to[0] - from[0], selection_width, 2
    touch("touchEnd")

    assert_current_path(%r{/\?.*start_date=.*end_date=})
    params = Rack::Utils.parse_query(URI.parse(page.current_url).query)
    assert_operator Date.parse(params["start_date"]), :<, Date.parse(params["end_date"])
  end

  test "a long press lifted without sliding selects nothing and keeps the tooltip" do
    point = chart_point(0.4)

    touch("touchStart", point)
    sleep 0.7
    touch("touchEnd")

    assert tooltip_visible?, "the tooltip went away"
    assert_no_selector "#{CHART} .touch-selection", visible: :all
    assert_nil URI.parse(page.current_url).query
  end

  # Dashboard cards are reordered by holding them (800 ms); a hold on the
  # chart selects a range and must not lift its card.
  test "holding a finger on the chart does not pick up its dashboard card" do
    point = chart_point(0.4)

    touch("touchStart", point)
    sleep 1.2
    assert_selector "#{CHART} .touch-selection", visible: :all
    grabbed = page.evaluate_script(%(document.querySelector("#{CHART}").closest("[data-sortable-list-target='item']").getAttribute("aria-grabbed")))
    touch("touchEnd")

    assert_equal "false", grabbed, "the hold picked up the dashboard card"
  end

  test "holding a finger on the chart's margin does not pick up its dashboard card" do
    # Above the plotting area, in the <svg>'s own top margin.
    svg = page.evaluate_script(%((() => { const r = document.querySelector("#{CHART} svg").getBoundingClientRect(); return [r.left + r.width / 2, r.top + 4] })()))
    assert_equal "svg", page.evaluate_script(%(document.elementFromPoint(#{svg[0]}, #{svg[1]}).tagName)), "the point is not on the chart's margin"

    touch("touchStart", svg)
    sleep 1.2
    grabbed = page.evaluate_script(%(document.querySelector("#{CHART}").closest("[data-sortable-list-target='item']").getAttribute("aria-grabbed")))
    touch("touchEnd")

    assert_equal "false", grabbed, "a hold on the chart's margin picked up the dashboard card"
  end

  # During a selection a one-finger drift up or down must not scroll the page,
  # but a second finger makes it a pinch, which zooms as anywhere else.
  # A browser may end the gesture itself (pointercancel) after the long press;
  # the selection goes, the tooltip stays, nothing opens, and a new touch works.
  test "a long press the browser cancels leaves the tooltip and lets the next touch start" do
    point = chart_point(0.4)

    touch("touchStart", point)
    # Waits for the selection, then cancels at once (an idle finger held
    # much longer may be cancelled by the browser itself).
    assert_selector "#{CHART} .touch-selection", visible: :all
    touch("touchMove", [ point[0] + 40, point[1] ])
    page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: "touchCancel", touchPoints: [])

    assert_no_selector "#{CHART} .touch-selection", visible: :all
    assert tooltip_visible?, "the tooltip went away"
    assert_nil URI.parse(page.current_url).query

    from = chart_point(0.2)
    touch("touchStart", from)
    touch("touchMove", [ from[0] + 30, from[1] ])
    first_date = tooltip_date
    slide([ from[0] + 30, from[1] ], chart_point(0.7))
    touch("touchEnd")
    assert_not_equal first_date, tooltip_date, "a touch after the cancelled one did not scrub"
  end

  # On a dense period (365 days over a few hundred pixels) a finger's drift
  # while lifting reaches another day; it must not open a range.
  test "a finger drifting a few pixels after a long press opens nothing" do
    visit root_path(period: "last_365_days")
    assert_selector "#{CHART} .drag-select-brush .overlay", visible: :all
    page.execute_script(%(document.querySelector("#{CHART}").scrollIntoView({ block: "center" })))
    assert_operator point_spacing, :<, 7, "the period is not dense enough for a 7px drift to reach another day"
    point = chart_point(0.4)

    touch("touchStart", point)
    assert_selector "#{CHART} .touch-selection", visible: :all
    touch("touchMove", [ point[0] + 7, point[1] ])
    touch("touchEnd")

    assert tooltip_visible?, "the tooltip went away"
    assert_no_match(/start_date/, page.current_url, "a drift after the long press opened a range")
  end

  # A second finger starts a pinch: lifting the first must not open a range,
  # whether the long press had already started a selection or not.
  test "a second finger cancels a long press and a selection" do
    point = chart_point(0.3)
    two = ->(a) { page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: "touchStart", touchPoints: [ { x: a[0], y: a[1] }, { x: a[0] + 120, y: a[1] + 10 } ]) }

    touch("touchStart", point)
    two.call(point)
    sleep 0.7
    assert_no_selector "#{CHART} .touch-selection", visible: :all
    touch("touchEnd")
    assert_nil URI.parse(page.current_url).query

    touch("touchStart", point)
    assert_selector "#{CHART} .touch-selection", visible: :all
    slide(point, chart_point(0.6))
    two.call(chart_point(0.6))
    assert_no_selector "#{CHART} .touch-selection", visible: :all
    touch("touchEnd")
    assert_nil URI.parse(page.current_url).query, "lifting after a second finger opened a range"
  end

  # A second finger has its own target: on the chart's margin it never reaches
  # the plotting overlay, and must still cancel the selection.
  test "a second finger on the chart's margin cancels a selection" do
    point = chart_point(0.3)
    margin = page.evaluate_script(%((() => { const r = document.querySelector("#{CHART} svg").getBoundingClientRect(); return [r.left + r.width / 2, r.top + 4] })()))
    assert_equal "svg", page.evaluate_script(%(document.elementFromPoint(#{margin[0]}, #{margin[1]}).tagName)), "the point is not on the chart's margin"

    touch("touchStart", point)
    assert_selector "#{CHART} .touch-selection", visible: :all
    slide(point, chart_point(0.6))
    # Real two-finger input makes Chrome cancel the first pointer itself; a
    # browser that waits for the fingers to move does not. The second
    # finger's pointerdown alone, on the margin, has to end the selection.
    page.execute_script(<<~JS, margin[0], margin[1])
      const [x, y] = arguments;
      document.elementFromPoint(x, y).dispatchEvent(new PointerEvent("pointerdown",
        { bubbles: true, cancelable: true, pointerType: "touch", pointerId: 99, isPrimary: false, clientX: x, clientY: y }));
    JS
    touch("touchEnd")

    assert_no_selector "#{CHART} .touch-selection", visible: :all
    sleep 1 # a range opens through Turbo.visit, after the lift
    assert_nil URI.parse(page.current_url).query, "lifting after a second finger on the margin opened a range"
  end

  # The tooltip stays after a tap, with its guideline; a touch landing on that
  # line must still reach the chart.
  test "a touch on the tooltip's guideline still scrubs" do
    point = chart_point(0.5)
    touch("touchStart", point)
    touch("touchEnd")
    assert tooltip_visible?
    first_date = tooltip_date
    # On the first painted dash of the dashed line.
    line = page.evaluate_script(%((() => { const r = document.querySelector("#{CHART} .guideline").getBoundingClientRect(); return [r.left + r.width / 2, r.top + 2] })()))

    touch("touchStart", line)
    slide(line, [ line[0] + 120, line[1] ], steps: 6)
    touch("touchEnd")

    assert_not_equal first_date, tooltip_date, "a touch on the guideline did not scrub"
  end

  test "a selection keeps one finger from scrolling but leaves a pinch to the browser" do
    page.execute_script(<<~JS)
      window.__moves = []
      document.addEventListener("touchmove", (event) => window.__moves.push([event.touches.length, event.defaultPrevented]))
    JS
    point = chart_point(0.4)

    touch("touchStart", point)
    sleep 0.7
    touch("touchMove", [ point[0] + 15, point[1] + 5 ])
    # A second finger lands (touchStart with both), then both move.
    page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: "touchStart",
      touchPoints: [ { x: point[0] + 15, y: point[1] + 5 }, { x: point[0] + 60, y: point[1] + 30 } ])
    page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: "touchMove",
      touchPoints: [ { x: point[0] + 10, y: point[1] }, { x: point[0] + 80, y: point[1] + 50 } ])
    touch("touchEnd")

    moves = page.evaluate_script("window.__moves")
    assert_includes moves, [ 1, true ], "a one-finger move during a selection was not kept from scrolling: #{moves.inspect}"
    assert_includes moves, [ 2, false ], "a two-finger move during a selection was cancelled: #{moves.inspect}"
  end

  test "a slide without the long press only moves the tooltip and selects nothing" do
    from = chart_point(0.3)
    middle = chart_point(0.5)
    to = chart_point(0.7)

    # Resting past the long press in the middle of a slide: a finger that
    # already moved is scrubbing, so going on must not select.
    touch("touchStart", from)
    slide(from, middle)
    sleep 0.7
    assert_no_selector "#{CHART} .touch-selection", visible: :all
    slide(middle, to)
    touch("touchEnd")

    assert_no_selector "#{CHART} .touch-selection", visible: :all
    assert_equal "/", URI.parse(page.current_url).path
    assert_nil URI.parse(page.current_url).query
  end

  test "a vertical swipe on the chart scrolls the page and hides the tooltip" do
    page.driver.browser.manage.window.resize_to(1400, 700)
    page.execute_script(%(document.querySelector("#{CHART}").scrollIntoView({ block: "center" })))
    before = scroll_offsets
    start = chart_point(0.5)

    touch("touchStart", start)
    slide(start, [ start[0], start[1] - 250 ], steps: 12)
    touch("touchEnd")

    assert_equal "pan-y pinch-zoom", page.evaluate_script(%(getComputedStyle(document.querySelector("#{CHART} svg")).touchAction)),
      "the chart takes horizontal slides and leaves vertical scrolling and pinch zoom to the browser"
    assert_not_equal before, scroll_offsets, "the page did not scroll"
    assert_not tooltip_visible?, "the tooltip stayed after the page scrolled"
    assert_no_selector "#{CHART} .touch-selection", visible: :all
    assert_equal "/", URI.parse(page.current_url).path
  end

  # Emulated mouse events are ignored for a moment after a touch, timed with
  # performance.now(), which counts from the page load. Held at 500 ms, the
  # page stays in its first second: with no touch yet, the mouse must work.
  test "the mouse works before any touch, even in the page's first second" do
    clock = page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: "performance.now = () => 500")
    visit root_path
    assert_selector "#{CHART} .drag-select-brush .overlay", visible: :all
    page.execute_script(%(document.querySelector("#{CHART}").scrollIntoView({ block: "center" })))

    # A mouse move dispatched in the page rather than a WebDriver action,
    # which would leave input state behind for the touch tests.
    page.execute_script(<<~JS)
      const overlay = document.querySelector("#{CHART} .drag-select-brush .overlay");
      const r = overlay.getBoundingClientRect();
      overlay.dispatchEvent(new MouseEvent("mousemove", { bubbles: true, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 }));
    JS

    assert tooltip_visible?, "hovering showed no tooltip"
  ensure
    # Registered for every later page in this browser, not only this visit.
    page.driver.browser.execute_cdp("Page.removeScriptToEvaluateOnNewDocument", identifier: clock["identifier"]) if clock
  end

  private
    def touch(type, point = nil)
      points = point ? [ { x: point[0], y: point[1] } ] : []
      page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: type, touchPoints: points)
    end

    def slide(from, to, steps: 10)
      (1..steps).each do |step|
        x = from[0] + (to[0] - from[0]) * step / steps.to_f
        y = from[1] + (to[1] - from[1]) * step / steps.to_f
        touch("touchMove", [ x, y ])
      end
    end

    def chart_box
      page.evaluate_script(<<~JS)
        (() => {
          const r = document.querySelector("#{CHART} .drag-select-brush .overlay").getBoundingClientRect()
          return { left: r.left, top: r.top, width: r.width, height: r.height }
        })()
      JS
    end

    # A point at a fraction of the chart's width, halfway down, in viewport pixels.
    def chart_point(fraction)
      box = chart_box
      [ box["left"] + box["width"] * fraction, box["top"] + box["height"] / 2 ]
    end

    def point_spacing
      count = page.evaluate_script(%(JSON.parse(document.querySelector("#{CHART}").dataset.timeSeriesChartDataValue).values.length))
      chart_box["width"] / [ count - 1, 1 ].max
    end

    def guideline_x
      page.evaluate_script(%(Number(document.querySelector("#{CHART} .guideline").getAttribute("x1"))))
    end

    def tooltip_date
      page.evaluate_script(%(document.querySelector("#{CHART} > .chart-tooltip .text-secondary")?.textContent.trim()))
    end

    def tooltip_visible?
      # Shown and hidden through its inline opacity (the class starts it hidden).
      page.evaluate_script(%(document.querySelector("#{CHART} > .chart-tooltip").style.opacity)) == "1"
    end

    # Every scrollable box's offset, since the page scrolls inside the layout.
    def scroll_offsets
      page.evaluate_script(<<~JS)
        [document.scrollingElement.scrollTop, ...Array.from(document.querySelectorAll("*")).filter((el) => el.scrollHeight > el.clientHeight && /auto|scroll/.test(getComputedStyle(el).overflowY)).map((el) => el.scrollTop)]
      JS
    end
end
