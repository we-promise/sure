require "application_system_test_case"

class DashboardGridlinesTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)

    # Test mode turns CSRF protection off, which also drops the csrf-token meta
    # tag the widget's background save reads (and refuses to send without).
    # Turn it on so the switch is exercised end to end, save included.
    @forgery_protection_was = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_protection_was
  end

  test "the Net Worth gridlines switch draws the lines live and the choice survives a reload" do
    sign_in @user
    assert_selector "#netWorthChart svg path", visible: :all
    assert_no_selector "#netWorthChart svg .y-gridlines", visible: :all

    toggle_gridlines
    assert_selector "#netWorthChart svg .y-gridlines line", minimum: 2, visible: :all
    assert_selector "#netWorthChart svg .y-gridline-labels text", minimum: 2, visible: :all
    wait_until { @user.reload.dashboard_section_gridlines?("net_worth_chart") }

    visit root_path
    assert_selector "#netWorthChart svg .y-gridlines line", minimum: 2, visible: :all

    toggle_gridlines
    assert_no_selector "#netWorthChart svg .y-gridlines", visible: :all
    wait_until { !@user.reload.dashboard_section_gridlines?("net_worth_chart") }
  end

  # Regression: the date-label styling once selected every `.tick text` in the
  # chart, so it also restyled the gridline labels (pulling them into the plot,
  # under the lines) and mis-numbered the two dates (pushing the start date off
  # the left edge). Labels must sit in the gutter beyond the lines, and both
  # dates must be drawn inside the chart, below the bottom line.
  test "gridline labels sit beyond the lines and both dates stay visible below them" do
    @user.update_dashboard_preferences({ "dashboard_section_layout" => { "net_worth_chart" => { "gridlines" => true } } })
    sign_in @user
    assert_selector "#netWorthChart svg .y-gridlines line", minimum: 2, visible: :all
    use_varied_series("#netWorthChart")
    assert_selector "#netWorthChart svg .y-gridline-labels text", minimum: 3, visible: :all

    g = page.evaluate_script(<<~JS)
      (() => {
        const svg = document.querySelector("#netWorthChart svg");
        const rects = (sel) => [...svg.querySelectorAll(sel)].map((n) => n.getBoundingClientRect());
        const lines = rects(".y-gridlines line");
        const labels = rects(".y-gridline-labels text");
        const dates = rects(".x-axis-labels text");
        const s = svg.getBoundingClientRect();
        const min = (a, k) => Math.min(...a.map((r) => r[k]));
        const max = (a, k) => Math.max(...a.map((r) => r[k]));
        return {
          lineRight: max(lines, "right"), lineBottom: max(lines, "bottom"),
          labelLeft: min(labels, "left"), labelRight: max(labels, "right"),
          dateCount: dates.length, dateLeft: min(dates, "left"), dateRight: max(dates, "right"),
          dateTop: min(dates, "top"), dateBottom: max(dates, "bottom"),
          svgLeft: s.left, svgRight: s.right, svgBottom: s.bottom,
        };
      })()
    JS

    assert_operator g["labelLeft"], :>=, g["lineRight"] - 0.5, "gridline labels overlap the lines"
    assert_operator g["labelRight"], :<=, g["svgRight"] + 0.5, "gridline labels are clipped on the right"
    assert_equal 2, g["dateCount"]
    assert_operator g["dateLeft"], :>=, g["svgLeft"] - 0.5, "start date is cut off on the left"
    assert_operator g["dateRight"], :<=, g["svgRight"] + 0.5, "end date is cut off on the right"
    assert_operator g["dateTop"], :>=, g["lineBottom"], "dates collide with the bottom gridline"
    assert_operator g["dateBottom"], :<=, g["svgBottom"] + 0.5, "dates are cut off at the bottom"
  end

  test "the Spending chart still draws its gridlines through the shared module" do
    sign_in @user

    assert_selector "[data-controller='spending-chart'] svg .y-gridlines line", minimum: 2, visible: :all
    assert_selector "[data-controller='spending-chart'] svg .y-gridline-labels text", minimum: 2, visible: :all
  end

  private
    def toggle_gridlines
      section = find("[data-section-key='net_worth_chart']")
      section.hover
      section.find("summary").click
      find("label[for='gridlines-net_worth_chart']", match: :first).click
    end

    # The fixture family's balances are constant, so the real series is flat.
    # Swap in a varied one and let the chart redraw (it reinstalls on turbo:load).
    def use_varied_series(selector)
      page.execute_script(<<~JS)
        const el = document.querySelector("#{selector}");
        const data = JSON.parse(el.getAttribute("data-time-series-chart-data-value"));
        const last = data.values.length - 1;
        data.values.forEach((point, i) => {
          point.value = { ...point.value, amount: String(110400 + (4000 * i) / last + 900 * Math.sin(i / 2)) };
        });
        el.setAttribute("data-time-series-chart-data-value", JSON.stringify(data));
        document.dispatchEvent(new Event("turbo:load"));
      JS
    end

    def wait_until(timeout: 5)
      deadline = Time.current + timeout
      sleep 0.1 until yield || Time.current > deadline
      assert yield, "condition not met within #{timeout}s"
    end
end
