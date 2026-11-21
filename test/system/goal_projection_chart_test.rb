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
    # Stays on TODAY until each test's own travel_to: a request the signed-in
    # page makes at the real date would find a session last touched on TODAY,
    # expire it once TODAY is Session::INACTIVITY_TIMEOUT behind, and log out.
    travel_to TODAY
    sign_in @user
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

  test "the target label is painted above the plot lines and under the dots" do
    travel_to TODAY do
      visit_goal(target: 10_000, saved: 3_000, pace: 330)

      order = page.evaluate_script(<<~JS)
        (() => {
          const kids = Array.from(document.querySelector("[data-controller='goal-projection-chart'] svg").children);
          const label = kids.findIndex((n) => n.tagName === "text" && n.textContent.startsWith("Target"));
          const lastPath = kids.map((n) => n.tagName).lastIndexOf("path");
          const circles = kids
            .map((n, i) => (n.tagName === "circle" && n.style.display !== "none" ? i : -1))
            .filter((i) => i >= 0);
          return { label, lastPath, circles };
        })()
      JS
      assert_operator order["lastPath"], :>=, 0, "premise: plot paths drawn"
      assert_operator order["label"], :>, order["lastPath"], "a line drawn after the label paints over its halo"
      assert_equal 2, order["circles"].size, "premise: the Today and projection-end dots are drawn"
      order["circles"].each do |circle|
        assert_operator circle, :>, order["label"], "the label's halo is painted over a dot"
      end
    end
  end

  test "on an overdue goal just short of its target the target label clears Today and the shortfall label" do
    travel_to TODAY do
      visit_goal(target: 10_000, saved: 9_900, target_date: TODAY, history_from: TODAY - 90.days)

      today_label = chart_texts.find { |t| t["text"] == "Today" }
      assert today_label, "premise: the Today label is drawn"
      assert_operator today_label["x"] + today_label["width"], :>, svg_width - 60, "premise: Today sits at the right edge"
      label = target_label
      assert_not boxes_overlap?(label, today_label), "Target and Today overlap: #{label.inspect} #{today_label.inspect}"
      assert_not boxes_overlap?(label, shortfall_label), "Target and shortfall overlap: #{label.inspect} #{shortfall_label.inspect}"
    end
  end

  # A target date a week away puts Today at the right edge, beside an end
  # label that sits near the top of the scale.
  test "a projection ending a week out keeps its labels clear of the Today label" do
    travel_to TODAY do
      visit_goal(target: 10_000, saved: 9_000, pace: 20_000, target_date: TODAY + 7.days, history_from: TODAY - 90.days)

      today_label = chart_texts.find { |t| t["text"] == "Today" }
      assert today_label, "premise: the Today label is drawn"
      chart_texts.reject { |t| t["text"] == "Today" }.each do |text|
        assert_not boxes_overlap?(text, today_label), "#{text["text"].inspect} overlaps Today: #{text.inspect} #{today_label.inspect}"
      end
    end
  end

  test "a window of daily ticks keeps the label of every month it covers" do
    travel_to Date.new(2027, 1, 25) do
      # The setup session is three months old by now.
      sign_in @user
      visit_goal(target: 10_000, target_date: Date.new(2027, 2, 1))
      resize_chart(428)

      labels = x_labels.map { |l| l["text"] }
      assert_equal [ "Jan 2027", "Feb 2027" ], labels
    end
  end

  test "an on-track projection ending at the target still drops its own end label" do
    travel_to TODAY do
      # $7,000 to go over ~24 months: the projection ends within a few dollars
      # of the target, so its end dot sits on the target line.
      goal = visit_goal(target: 10_000, saved: 3_000, pace: 291.67)
      end_label = Money.new(goal.projection_end_amount, "USD").format(precision: 0)

      end_dot_y = page.evaluate_script(<<~JS)
        Number(Array.from(document.querySelectorAll("[data-controller='goal-projection-chart'] svg circle"))
          .find((c) => c.getAttribute("fill") === "var(--color-green-600)").getAttribute("cy"))
      JS
      assert_operator (end_dot_y - target_line_y).abs, :<, COLLISION_PX, "premise: the projection ends on the target line"

      assert_equal "Target · $10,000", target_label["text"]
      assert_not_includes chart_texts.map { |t| t["text"] }, end_label, "the projection-end label must stay suppressed"
    end
  end

  # $3,000 saved at $280 a month ends about $280 short, so the end dot sits a
  # few pixels under the target line and both right-aligned labels share the
  # chart's right edge.
  test "a projection ending just short of the target keeps its shortfall label clear of the target label" do
    travel_to TODAY do
      visit_goal(target: 10_000, saved: 3_000, pace: 280)

      assert_operator (shortfall_dot_y - target_line_y).abs, :<, COLLISION_PX, "premise: the projection ends beside the target line"
      target = target_label
      shortfall = shortfall_label
      assert_not boxes_overlap?(target, shortfall), "the shortfall label overlaps the target label: #{[ target, shortfall ].inspect}"
      assert_operator shortfall["y"], :>, shortfall_dot_y, "the shortfall label moves below its dot"
    end
  end

  test "a projection ending well short of the target keeps its shortfall label above the dot" do
    travel_to TODAY do
      visit_goal(target: 10_000, saved: 3_000, pace: 200)

      assert_operator (shortfall_dot_y - target_line_y).abs, :>=, COLLISION_PX, "premise: the projection ends clear of the target line"
      assert_operator shortfall_label["y"] + shortfall_label["height"], :<=, shortfall_dot_y, "the shortfall label stays above its dot"
    end
  end

  # $3,000 saved at $200 a month: the projection falls short, so the chart
  # draws a halo'd shortfall label beside the halo'd target label.
  test "in the dark theme every halo and ring matches the card" do
    @user.update!(theme: "dark")
    travel_to TODAY do
      visit_goal(target: 10_000, saved: 3_000, pace: 200)
      assert_selector "html[data-theme='dark']"

      assert_backdrop_paint
    end
  end

  # The reported axis opens on Oct 2026, before the goal was created, so its
  # domain starts with the saved history: the 90 days the balance series
  # covers. Asked for "about 5" ticks, d3 then returns nine quarterly ones,
  # Oct 2026 to Oct 2028, about 52 px apart at this width.
  # Eight quarterly ticks, Oct 2026 to Jul 2028, thinned to every other one:
  # counted from the first label, the last (the goal's end) would be dropped.
  test "thinning the x-axis keeps the goal's end date" do
    travel_to TODAY do
      visit_goal(target: 10_000, target_date: Date.new(2028, 7, 22), history_from: TODAY - 90.days)
      resize_chart(560)

      labels = x_labels.map { |l| l["text"] }
      assert_operator labels.size, :<, 8, "premise: some labels are dropped to fit: #{labels}"
      assert_equal "Jul 2028", labels.last, "the goal's end date must keep its label: #{labels}"
    end
  end

  test "x-axis labels on a two-year goal do not overlap and keep the target date" do
    travel_to TODAY do
      visit_goal(target: 10_000, history_from: TODAY - 90.days)

      labels = x_labels
      assert_x_labels_clear(labels)
      assert_operator labels.size, :>=, 2, "thinning must not empty the axis"
      assert_equal "Oct 2028", labels.last["text"], "the goal's end date must keep its label: #{labels.map { |l| l["text"] }}"
      months = labels.map { |l| d = Date.strptime(l["text"], "%b %Y"); d.year * 12 + d.month }
      assert_equal 1, months.each_cons(2).map { |a, b| b - a }.uniq.size, "kept labels must advance by a regular interval: #{labels.map { |l| l["text"] }}"
    end
  end

  private

    # The saved history is pinned: empty by default, so the x-domain starts on
    # the day the goal was created; or one point at `history_from`, which is
    # where the domain then starts.
    # pace_measurable? is stubbed true: the test account has no transaction or
    # balance history, so the chart would otherwise draw no projection at all.
    def visit_goal(target:, saved: 3_000, pace: 0, target_date: TARGET_DATE, history_from: nil)
      Goal.any_instance.stubs(:pace).returns(pace)
      Goal.any_instance.stubs(:pace_measurable?).returns(true)
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
    # then redraws at the real width, and a font that finishes loading redraws
    # again, after `document.fonts.status` already reads "loaded". So wait for
    # the drawn width to match, the fonts to be loaded, and the same <svg> to
    # be found on two checks in a row: a redraw replaces it.
    def wait_for_settled_chart
      page.document.synchronize do
        settled = page.evaluate_script(<<~JS)
          (() => {
            const root = document.querySelector("[data-controller='goal-projection-chart']");
            const svg = root.querySelector("svg");
            const unchanged = !!svg && window.__settledChartSvg === svg;
            window.__settledChartSvg = svg;
            return unchanged && svg.viewBox.baseVal.width === root.clientWidth && document.fonts.status === "loaded";
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
          const rings = Array.from(svg.querySelectorAll("circle"))
            .map((c) => ({ fill: c.getAttribute("fill"), colour: getComputedStyle(c).stroke }));
          return { backdrop, halos, rings };
        })()
      JS
    end

    def assert_backdrop_paint
      paint = backdrop_paint
      # The target and shortfall labels; the projection end, Today and the two
      # hover dots.
      assert_operator paint["halos"].size, :>=, 2, "premise: halo'd labels drawn: #{paint["halos"].inspect}"
      assert_operator paint["rings"].size, :>=, 4, "premise: ringed dots drawn: #{paint["rings"].inspect}"

      backdrop = paint["backdrop"]
      (paint["halos"] + paint["rings"]).each do |item|
        assert_equal backdrop, item["colour"], "does not match the card behind the chart: #{item.inspect}"
      end
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

    def shortfall_label
      labels = chart_texts.select { |t| t["text"].end_with?(" short") }
      assert_equal 1, labels.size, "expected one shortfall label, got #{labels.inspect}"
      labels.first
    end

    # The end dot of a projection that falls short.
    def shortfall_dot_y
      page.evaluate_script(<<~JS)
        Number(Array.from(document.querySelectorAll("[data-controller='goal-projection-chart'] svg circle"))
          .find((c) => c.getAttribute("fill") === "var(--color-yellow-600)").getAttribute("cy"))
      JS
    end

    def boxes_overlap?(a, b)
      a["x"] < b["x"] + b["width"] && b["x"] < a["x"] + a["width"] &&
        a["y"] < b["y"] + b["height"] && b["y"] < a["y"] + a["height"]
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

    def resize_chart(width)
      page.execute_script("document.querySelector(\"[data-controller='goal-projection-chart']\").style.width = '#{width}px'")
      wait_for_settled_chart
    end

    def target_collides_with_gridline?
      ty = target_line_y
      gridline_ys.any? { |gy| (gy - ty).abs < COLLISION_PX }
    end
end
