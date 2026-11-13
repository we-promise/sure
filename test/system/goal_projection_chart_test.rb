require "application_system_test_case"

# What only a browser can say about the goal projection chart: where its text
# lands once laid out. Goal#projection_payload is covered by the model tests;
# these read the SVG the controller draws.
#
# The goal is the one the defects were reported against: $10,000 by
# 22 Oct 2028, created 22 Oct 2026, with $3,000 saved in one cash account.
class GoalProjectionChartTest < ApplicationSystemTestCase
  TODAY = Date.new(2026, 10, 22)
  TARGET_DATE = Date.new(2028, 10, 22)
  COLLISION_PX = 18

  setup do
    @user = users(:family_admin)
    # Goals sit behind the preview gate.
    @user.update!(
      preferences: (@user.preferences || {}).merge("preview_features_enabled" => true),
      show_ai_sidebar: false
    )
    travel_to(TODAY) { sign_in @user }
  end

  test "a target on a gridline keeps its full label inside the chart" do
    travel_to TODAY do
      visit_goal(target: 10_000)

      assert target_collides_with_gridline?, "premise: the $10,000 target must sit on a y-axis gridline"

      label = target_label
      assert_operator label["x"], :>=, 0, "the target label starts left of the chart: #{label.inspect}"
      assert_operator label["x"] + label["width"], :<=, svg_width, "the target label runs past the chart's right edge"
      assert_equal "Target · $10,000", label["text"], "the target label must use the full-format amount"
      # The gridline's own tick label is suppressed, so the row is labelled once.
      assert_not_includes chart_texts.map { |t| t["text"] }, "$10K"
    end
  end

  test "a target between gridlines keeps its right-hand label and every tick label" do
    travel_to TODAY do
      visit_goal(target: 7_300, saved: 3_000, pace: 0)

      assert_not target_collides_with_gridline?, "premise: the $7,300 target must sit clear of every gridline"

      label = target_label
      assert_equal "Target · $7,300", label["text"]
      assert_operator label["x"] + label["width"], :>, svg_width / 2, "the target label belongs on the right"
      assert_equal gridline_ys.size, y_tick_labels.size, "every gridline keeps its tick label"
    end
  end

  test "at phone width the target label stays on the right and in full" do
    travel_to TODAY do
      visit_goal(target: 10_000)
      on_phone

      assert_empty gridline_ys, "premise: the y-axis is hidden at phone width"
      label = target_label
      assert_equal "Target · $10,000", label["text"]
      assert_operator label["x"], :>=, 0
      assert_operator label["x"] + label["width"], :<=, svg_width
    end
  end

  test "an on-track projection ending at the target still drops its own end label" do
    travel_to TODAY do
      # $7,000 to go over ~24 months: the projection ends within a few dollars
      # of the target, so its end dot sits on the target line.
      goal = visit_goal(target: 10_000, saved: 3_000, pace: 291.67)
      end_label = Money.new(goal.projection_end_amount(as_of: TODAY), "USD").format(precision: 0)

      end_dot_y = page.evaluate_script(<<~JS)
        Number(Array.from(document.querySelectorAll("[data-controller='goal-projection-chart'] svg circle"))
          .find((c) => c.getAttribute("fill") === "var(--color-green-600)").getAttribute("cy"))
      JS
      assert_operator (end_dot_y - target_line_y).abs, :<, COLLISION_PX, "premise: the projection ends on the target line"

      assert_equal "Target · $10,000", target_label["text"]
      assert_not_includes chart_texts.map { |t| t["text"] }, end_label, "the projection-end label must stay suppressed"
    end
  end

  # $3,000 saved at $200 a month: the projection falls short (a halo'd
  # shortfall label), and the 50% and 75% milestones are drawn before the
  # target date (hollow dots and halo'd labels).
  test "in the dark theme every halo and ring matches the card" do
    @user.update!(theme: "dark")
    travel_to TODAY do
      visit_goal(target: 10_000, saved: 3_000, pace: 200)
      assert_selector "html[data-theme='dark']"

      assert_backdrop_paint
    end
  end

  test "in the light theme every halo and ring matches the card" do
    @user.update!(theme: "light")
    travel_to TODAY do
      visit_goal(target: 10_000, saved: 3_000, pace: 200)
      assert_selector "html[data-theme='light']"

      assert_backdrop_paint
    end
  end

  test "switching to the dark theme repaints the halos to the dark card" do
    @user.update!(theme: "light")
    travel_to TODAY do
      visit_goal(target: 10_000, saved: 3_000, pace: 200)
      light_card = backdrop_paint["backdrop"]

      page.execute_script("document.documentElement.setAttribute('data-theme', 'dark')")
      page.document.synchronize do
        raise Capybara::ExpectationNotMet, "the card has not changed theme" if backdrop_paint["backdrop"] == light_card
      end

      assert_backdrop_paint
    end
  end

  # The reported axis opens on Oct 2026, before the goal was created, so its
  # domain starts with the saved history: the 90 days the balance series
  # covers. Asked for "about 5" ticks, d3 then returns nine quarterly ones,
  # Oct 2026 to Oct 2028, about 52 px apart at this width.
  test "x-axis labels on a two-year goal do not overlap at desktop width" do
    travel_to TODAY do
      visit_goal(target: 10_000, history_from: TODAY - 90.days)

      assert_equal 9, raw_x_ticks, "premise: d3 returns nine quarterly ticks for the reported goal"
      labels = x_labels
      assert_x_labels_clear(labels)
      assert_operator labels.size, :<, raw_x_ticks, "some labels must be dropped to fit"
      assert_operator labels.size, :>=, 2, "thinning must not empty the axis"
    end
  end

  test "a short goal keeps every x-axis tick" do
    travel_to TODAY do
      visit_goal(target: 10_000, history_from: TODAY - 90.days, target_date: TODAY + 3.months)

      assert_equal raw_x_ticks, x_labels.size, "labels that already fit must all be kept"
      assert_x_labels_clear(x_labels)
    end
  end

  test "at phone width the x-axis keeps its yearly ticks" do
    travel_to TODAY do
      visit_goal(target: 10_000, history_from: TODAY - 90.days)
      on_phone

      assert_equal [ "Jan 2027", "Jan 2028" ], x_labels.map { |l| l["text"] }
      assert_equal raw_x_ticks, x_labels.size
    end
  end

  test "a chart narrower than one label still draws a label, without error" do
    travel_to TODAY do
      visit_goal(target: 10_000, history_from: TODAY - 90.days)

      page.execute_script(<<~JS)
        window.__chartErrors = [];
        window.addEventListener("error", (e) => window.__chartErrors.push(String(e.message)));
        document.querySelector("[data-controller='goal-projection-chart']").style.width = "120px";
      JS
      wait_for_settled_chart

      assert_equal 120, svg_width, "premise: the chart redrew at 120 px"
      assert_operator x_labels.size, :>=, 1
      assert_empty page.evaluate_script("window.__chartErrors")
    end
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") if @phone
  end

  private

    # Chrome will not size a window below 500 px, so a phone is emulated.
    # The chart redraws from its ResizeObserver at the new width.
    def on_phone
      @phone = true
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
      wait_for_settled_chart
    end

    # The saved history is pinned: empty by default, so the x-domain starts on
    # the day the goal was created; or one point at `history_from`, which is
    # where the domain then starts.
    def visit_goal(target:, saved: 3_000, pace: 0, target_date: TARGET_DATE, history_from: nil)
      Goal.any_instance.stubs(:pace).returns(pace)
      history = history_from ? [ OpenStruct.new(date: history_from, value: Money.new(saved, "USD")) ] : []
      Goal.any_instance.stubs(:balance_series_values).returns(history)

      account = @user.family.accounts.create!(name: "Holiday savings", accountable: Depository.new, currency: "USD", balance: saved)
      goal = @user.family.goals.create!(
        name: "Japan holiday", target_amount: target, currency: "USD", target_date: target_date,
        goal_accounts: [ GoalAccount.new(account: account) ]
      )

      visit goal_path(goal)
      assert_selector "[data-controller='goal-projection-chart'] svg text", minimum: 1
      wait_for_settled_chart
      goal
    end

    # The first paint can land before the layout settles; the ResizeObserver
    # then redraws at the real width. Wait for the drawn width to match.
    def wait_for_settled_chart
      page.document.synchronize do
        settled = page.evaluate_script(<<~JS)
          (() => {
            const root = document.querySelector("[data-controller='goal-projection-chart']");
            const svg = root.querySelector("svg");
            return !!svg && svg.viewBox.baseVal.width === root.clientWidth;
          })()
        JS
        raise Capybara::ExpectationNotMet, "the chart has not redrawn at its settled width" unless settled
      end
    end

    # The colour each halo, ring and hollow dot resolves to, beside the colour
    # actually behind the chart: the nearest ancestor that paints a background.
    def backdrop_paint
      page.evaluate_script(<<~JS)
        (() => {
          const root = document.querySelector("[data-controller='goal-projection-chart']");
          let el = root;
          let backdrop = null;
          while (el && !backdrop) {
            const bg = getComputedStyle(el).backgroundColor;
            if (bg && bg !== "rgba(0, 0, 0, 0)" && bg !== "transparent") backdrop = bg;
            el = el.parentElement;
          }
          const svg = root.querySelector("svg");
          const halos = Array.from(svg.querySelectorAll("text[paint-order='stroke']"))
            .map((t) => ({ text: t.textContent, colour: getComputedStyle(t).stroke }));
          const milestones = Array.from(svg.querySelectorAll("circle[data-milestone]"))
            .map((c) => ({ percent: c.dataset.milestone, colour: getComputedStyle(c).fill }));
          const rings = Array.from(svg.querySelectorAll("circle:not([data-milestone])"))
            .map((c) => ({ fill: c.getAttribute("fill"), colour: getComputedStyle(c).stroke }));
          return { backdrop, halos, milestones, rings };
        })()
      JS
    end

    def assert_backdrop_paint
      paint = backdrop_paint
      # Target, shortfall and both milestone labels; both milestone dots; the
      # projection end, Today and the two hover dots.
      assert_operator paint["halos"].size, :>=, 4, "premise: halo'd labels drawn: #{paint["halos"].inspect}"
      assert_operator paint["milestones"].size, :>=, 2, "premise: milestone dots drawn: #{paint["milestones"].inspect}"
      assert_operator paint["rings"].size, :>=, 4, "premise: ringed dots drawn: #{paint["rings"].inspect}"

      backdrop = paint["backdrop"]
      (paint["halos"] + paint["milestones"] + paint["rings"]).each do |item|
        assert_equal backdrop, item["colour"], "does not match the card behind the chart: #{item.inspect}"
      end
    end

    def raw_x_ticks
      page.evaluate_script("Number(document.querySelector(\"[data-controller='goal-projection-chart'] g[data-axis='x']\").dataset.rawTicks)")
    end

    def x_labels
      page.evaluate_script(<<~JS)
        Array.from(document.querySelectorAll("[data-controller='goal-projection-chart'] g[data-axis='x'] text")).map((t) => {
          const b = t.getBBox();
          return { text: t.textContent, left: b.x, right: b.x + b.width };
        })
      JS
    end

    def assert_x_labels_clear(labels)
      labels.each_cons(2) do |a, b|
        assert_operator a["right"] + 4, :<=, b["left"], "#{a["text"]} runs into #{b["text"]}: #{labels.inspect}"
      end
    end

    def svg_width
      page.evaluate_script("document.querySelector(\"[data-controller='goal-projection-chart'] svg\").viewBox.baseVal.width")
    end

    # Every <text> in the chart with its laid-out box, in SVG user units.
    def chart_texts
      page.evaluate_script(<<~JS)
        Array.from(document.querySelectorAll("[data-controller='goal-projection-chart'] svg text")).map((t) => {
          const b = t.getBBox();
          return { text: t.textContent, x: b.x, y: b.y, width: b.width, height: b.height };
        })
      JS
    end

    def target_label
      labels = chart_texts.select { |t| t["text"].start_with?("Target") }
      assert_equal 1, labels.size, "expected one target label, got #{labels.inspect}"
      labels.first
    end

    # Solid horizontal lines across the plot: the y-axis gridlines.
    def gridline_ys
      page.evaluate_script(<<~JS)
        Array.from(document.querySelectorAll("[data-controller='goal-projection-chart'] svg line"))
          .filter((l) => l.getAttribute("y1") === l.getAttribute("y2") && !l.getAttribute("stroke-dasharray"))
          .map((l) => Number(l.getAttribute("y1")))
      JS
    end

    def target_line_y
      page.evaluate_script(<<~JS)
        Number(Array.from(document.querySelectorAll("[data-controller='goal-projection-chart'] svg line"))
          .find((l) => l.getAttribute("y1") === l.getAttribute("y2") && l.getAttribute("stroke-dasharray") === "3 3")
          .getAttribute("y1"))
      JS
    end

    def target_collides_with_gridline?
      ty = target_line_y
      gridline_ys.any? { |gy| (gy - ty).abs < COLLISION_PX }
    end

    # Short-money tick labels sit in the left gutter.
    def y_tick_labels
      chart_texts.select { |t| t["text"].match?(/\A\$[\d.,]+[KM]?\z/) && t["x"] < 44 }
    end
end
