require "application_system_test_case"

# Opening or closing a sidebar animates its width, which resizes the charts
# beside it on every frame. Charts that redrew on each of those frames made the
# animation stutter; they now stretch their drawing during the animation and
# draw once, at the size the animation ends on (utils/settled_resize).
class ChartSidebarResizeTest < ApplicationSystemTestCase
  include EntriesTestHelper
  NET_WORTH = "#main [data-controller~='time-series-chart']".freeze

  setup do
    sign_in users(:family_admin)
    page.driver.browser.manage.window.resize_to(1100, 900)
    visit root_path
    assert_selector "#{NET_WORTH} svg"
    wait_until_settled
  end

  teardown do
    page.execute_script("localStorage.clear()") rescue nil
  end

  test "a sidebar animation redraws each dashboard chart at most once, at its final size" do
    assert_selector "#main [data-controller~='sankey-chart'] svg"
    page.execute_script(<<~JS)
      // The charts that redraw through SettledResize (the donut sizes itself).
      window.__charts = Array.from(document.querySelectorAll("#main [data-controller]"))
        .filter((el) => el.dataset.controller.split(" ").some((name) => ["time-series-chart", "sankey-chart", "bar-chart", "spending-chart"].includes(name)));
      window.__draws = window.__charts.map(() => 0);
      window.__widths = window.__charts.map((chart) => chart.querySelector("svg")?.parentElement.clientWidth);
      new MutationObserver((mutations) => mutations.forEach((m) => m.addedNodes.forEach((node) => {
        if (node.nodeName !== "svg") return;
        const i = window.__charts.findIndex((chart) => chart.contains(node));
        if (i >= 0) window.__draws[i]++;
      }))).observe(document.getElementById("main"), { childList: true, subtree: true });
    JS
    before = net_worth_width
    toggle_left_sidebar
    wait_until_settled(changed_from: before)

    charts = nil
    page.document.synchronize(10) do
      charts = page.evaluate_script(<<~JS)
        window.__charts.map((chart, i) => {
          const svg = chart.querySelector("svg");
          const width = svg?.parentElement.clientWidth;
          return { name: `${i}:${chart.dataset.controller}`, draws: window.__draws[i], resized: width !== window.__widths[i],
                   // Drawn at its container's width, in its drawing coordinates too,
                   // and not stretched (a stretched drawing carries preserveAspectRatio).
                   fits: !!svg && Number(svg.getAttribute("width")) === width &&
                     (!svg.hasAttribute("viewBox") || Number(svg.getAttribute("viewBox").split(/[ ,]+/)[2]) === width) &&
                     !svg.hasAttribute("preserveAspectRatio") };
        })
      JS
      # Only charts whose width changed.
      raise Capybara::ExpectationNotMet, "a resized chart is still stretched: #{charts.inspect}" unless charts.all? { |chart| !chart["resized"] || chart["fits"] }
    end
    assert_operator charts.size, :>=, 4, "expected the dashboard's time-series, Sankey, bar and spending charts: #{charts.inspect}"
    draws = charts.to_h { |chart| [ chart["name"], chart["draws"] ] }
    puts "chart sidebar resize draws: #{draws.inspect}"
    charts.select { |chart| chart["resized"] }.each do |chart|
      assert_operator chart["draws"], :>=, 1, "#{chart["name"]} changed width but was never redrawn"
    end
    # One draw as the animation ends; a loaded machine can stall long enough
    # mid-animation to settle once early, so allow a second. Redrawing on every
    # frame was 6-7 draws per chart.
    draws.each do |chart, count|
      assert_operator count, :<=, 2, "#{chart} was drawn #{count} times during one sidebar animation"
    end
  end

  test "the chart's dates keep their shape and their place at the edges while a sidebar animates" do
    assert_selector "#{NET_WORTH} svg .tick text", count: 2
    page.execute_script(<<~JS)
      window.__labels = []; window.__sampling = true;
      // Measured after each frame is painted (resize observers run before the
      // paint, after requestAnimationFrame callbacks), so it sees what was shown.
      const afterPaint = (fn) => requestAnimationFrame(() => setTimeout(fn, 0));
      const sample = () => {
        const element = document.querySelector("#{NET_WORTH}");
        const container = element.getBoundingClientRect();
        const svg = element.querySelector("svg");
        const [first, last] = Array.from(element.querySelectorAll("svg .tick text")).map((t) => t.getBoundingClientRect());
        // On a slow machine this can run after the next animation step has
        // begun, measuring a layout the chart has not followed yet and that was
        // never painted: only count frames where the drawing fills its container.
        const painted = svg && Math.round(Number(svg.getAttribute("width"))) === Math.round(container.width);
        if (first && last && painted) window.__labels.push([Math.round(container.width), first.left - container.left, container.right - last.right, first.width, last.width]);
        if (window.__sampling) afterPaint(sample);
      };
      // The settled baseline, before the toggle; then after each paint.
      sample();
    JS
    before = net_worth_width
    toggle_left_sidebar
    wait_until_settled(changed_from: before)
    # The chart can settle between two samples: stop only once one at the
    # final width is in.
    final = net_worth_width
    page.document.synchronize(10) do
      last = page.evaluate_script("window.__labels.at(-1)?.[0]")
      raise Capybara::ExpectationNotMet, "no sample at the final width yet (last: #{last.inspect})" unless last == final
    end
    page.execute_script("window.__sampling = false")

    samples = page.evaluate_script("window.__labels")
    widths = samples.map(&:first)
    assert_equal before, widths.first, "sampling began after the animation had started"
    assert_equal net_worth_width, widths.last, "sampling ended before the animation finished"
    assert widths.any? { |width| width != widths.first && width != widths.last }, "no sample fell inside the animation: #{widths.uniq.inspect}"

    spread = samples.transpose.drop(1).map { |values| (values.max - values.min).round(1) }
    puts "date labels (left gap, right gap, widths) spread: #{spread.inspect}"
    assert spread.all? { |value| value <= 2 }, "the dates moved or changed shape during the animation: #{spread.inspect}"
  end

  # A quick drag back and forth can bring a chart back to the size it was drawn
  # at before it settles; its drawing must not stay stretched to the last size.
  test "a chart resized and back before it settles fits its container again" do
    result = page.evaluate_async_script(<<~JS)
      const done = arguments[0];
      const element = document.querySelector("#{NET_WORTH}");
      const original = element.clientWidth;
      element.style.width = Math.round(original * 0.6) + "px";
      requestAnimationFrame(() => requestAnimationFrame(() => {
        element.style.width = "";
        requestAnimationFrame(() => requestAnimationFrame(() => {
          const svg = element.querySelector("svg");
          done({ container: element.clientWidth, svg: Number(svg.getAttribute("width")), original, stretched: svg.hasAttribute("preserveAspectRatio") });
        }));
      }));
    JS

    assert_equal result["original"], result["container"]
    assert_equal result["container"], result["svg"], "the chart's drawing stayed stretched to the intermediate size: #{result.inspect}"
    assert_not result["stretched"], "the chart is back at its drawn size but still marked as stretched (preserveAspectRatio)"
  end

  # Only a width transition that can resize the chart (a sidebar beside it)
  # holds its redraw back until it ends; one elsewhere on the page, or out of
  # the layout, must not.
  test "a width transition elsewhere on the page does not hold back a resized chart's redraw" do
    {
      "in a box of its own" => "const box = document.createElement('div'); box.append(bar); document.body.append(box);",
      "fixed, directly in the body" => "bar.style.position = 'fixed'; bar.style.top = '0'; document.body.append(bar);"
    }.each do |where, place|
      visit root_path
      assert_selector "#{NET_WORTH} svg"
      wait_until_settled

      elapsed = page.evaluate_async_script(<<~JS)
        const done = arguments[0];
        const bar = document.createElement("div");
        bar.style.cssText = "width: 0; height: 1px; transition: width 3s linear";
        #{place}
        requestAnimationFrame(() => requestAnimationFrame(() => {
          bar.style.width = "200px";
          requestAnimationFrame(() => {
            const element = document.querySelector("#{NET_WORTH}");
            const started = performance.now();
            element.style.width = Math.round(element.clientWidth * 0.6) + "px";
            const check = () => {
              const svg = element.querySelector("svg");
              if (svg && Number(svg.getAttribute("width")) === element.clientWidth && !svg.hasAttribute("preserveAspectRatio")) done(performance.now() - started);
              else if (performance.now() - started > 3000) done(null);
              else requestAnimationFrame(check);
            };
            requestAnimationFrame(check);
          });
        }));
      JS

      assert elapsed, "the resized chart was never redrawn (transition #{where})"
      assert_operator elapsed, :<, 700, "the resized chart waited for an unrelated transition #{where} (#{elapsed.round} ms)"
    end
  end

  # The bar chart's month labels step down (full, short, every other) as it
  # narrows. A stretched drawing would keep the starting labels across such a
  # step, overlapping or needlessly cut back until the end: it redraws then.
  test "the bar chart shows the labels that fit its width on every frame of a sidebar animation" do
    page.driver.browser.manage.window.resize_to(1400, 900)
    visit root_path
    bar = "#main [data-controller~='bar-chart']"
    assert_selector "#{bar} svg"
    page.execute_script(%(document.querySelector("#{bar}").scrollIntoView({ block: "center" })))
    wait_until_settled

    # Twelve months, so the step from full labels ("Jan 2026") to short ones
    # ("Jan") falls inside the range the sidebar toggle moves this chart
    # through. Set as the chart's data attribute; a size change draws it.
    page.execute_script(<<~JS)
      const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
      window.__months = months;
      const element = document.querySelector("#{bar}");
      element.setAttribute("data-bar-chart-data-value", JSON.stringify(months.map((m, i) => ({ label: `${m} 2026`, short_label: m, income: 1000 + i * 50, expense: 800 + i * 40, highlighted: i === 11 }))));
      element.style.width = `${element.clientWidth - 1}px`;
      // Held long enough to settle (and draw) before going back.
      setTimeout(() => { element.style.width = ""; }, 400);
    JS
    page.document.synchronize(10) do
      count = page.evaluate_script(%(Array.from(document.querySelectorAll("#{bar} svg g text")).filter((t) => window.__months.some((m) => t.textContent.startsWith(m))).length))
      raise Capybara::ExpectationNotMet, "the twelve months are not drawn yet (#{count})" unless count == 12
    end

    # What a drawing shows, read from the page: every other label hidden,
    # short labels, or full ones; and whether two shown labels overlap.
    page.execute_script(<<~JS)
      window.__shown = (element) => {
        const labels = Array.from(element.querySelectorAll("svg g text")).filter((t) => window.__months.some((m) => t.textContent.startsWith(m)));
        const visible = labels.filter((t) => t.style.display !== "none" && t.getAttribute("display") !== "none");
        const boxes = visible.map((t) => t.getBoundingClientRect()).sort((a, b) => a.left - b.left);
        const overlap = boxes.some((box, i) => i > 0 && box.left < boxes[i - 1].right);
        const mode = visible.length < labels.length ? "alternate" : labels.every((t, i) => t.textContent === window.__months[i]) ? "short" : "full";
        return { mode, overlap };
      };
    JS

    page.execute_script(<<~JS)
      window.__frames = []; window.__sampling = true;
      const element = document.querySelector("#{bar}");
      const afterPaint = (fn) => requestAnimationFrame(() => setTimeout(fn, 0));
      const sample = () => {
        const svg = element.querySelector("svg");
        const width = element.clientWidth;
        if (svg && Math.round(Number(svg.getAttribute("width"))) === width) {
          const { mode, overlap } = window.__shown(element);
          window.__frames.push([width, mode, overlap]);
        }
        if (window.__sampling) afterPaint(sample);
      };
      sample();
    JS
    before = net_worth_width
    toggle_left_sidebar
    wait_until_settled(changed_from: before)
    sleep 0.3
    page.execute_script("window.__sampling = false")
    frames = page.evaluate_script("window.__frames")

    # What the chart shows when drawn at rest at each of those widths.
    widths = frames.map(&:first).uniq
    settled = page.evaluate_async_script(<<~JS, widths)
      const [widths, done] = arguments;
      const element = document.querySelector("#{bar}");
      const result = {};
      const next = (i) => {
        if (i === widths.length) { element.style.width = ""; return done(result); }
        element.style.width = `${widths[i]}px`;
        const wait = (tries) => {
          const svg = element.querySelector("svg");
          const drawn = svg && Number(svg.getAttribute("width")) === widths[i] && !svg.hasAttribute("preserveAspectRatio");
          if (drawn || tries > 40) { result[widths[i]] = window.__shown(element).mode; next(i + 1); }
          else setTimeout(() => wait(tries + 1), 50);
        };
        setTimeout(() => wait(0), 50);
      };
      next(0);
    JS

    assert_operator settled.values.uniq.size, :>, 1, "the toggle never crossed a label step (widths #{widths.inspect}, at rest #{settled.inspect})"
    overlapping = frames.select(&:last).map(&:first)
    assert_empty overlapping, "labels overlapped on frames at widths #{overlapping.inspect}"
    wrong = frames.reject { |width, mode, _| mode == settled[width.to_s] }.map { |width, mode, _| [ width, mode, settled[width.to_s] ] }
    assert_empty wrong, "frames showing other labels than the chart draws at rest at their width (width, shown, at rest): #{wrong.uniq.inspect}"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  # A Turbo morph can replace a sidebar while it animates; its transition then
  # never reports an end, and must not hold back every later redraw.
  test "a sidebar removed mid-animation does not hold back a resized chart's redraw" do
    page.execute_script(%(if (!document.querySelector("[name='csrf-token']")) { const m = document.createElement("meta"); m.name = "csrf-token"; m.content = "test"; document.head.append(m) }))
    elapsed = page.evaluate_async_script(<<~JS)
      const done = arguments[0];
      document.querySelector("[data-action='app-layout#toggleLeftSidebar']").click();
      setTimeout(() => {
        document.querySelector("[data-app-layout-target='leftSidebar']").remove();
        setTimeout(() => {
          const element = document.querySelector("#{NET_WORTH}");
          const started = performance.now();
          element.style.width = Math.round(element.clientWidth * 0.6) + "px";
          const check = () => {
            const svg = element.querySelector("svg");
            if (svg && Number(svg.getAttribute("width")) === element.clientWidth && !svg.hasAttribute("preserveAspectRatio")) done(performance.now() - started);
            else if (performance.now() - started > 3000) done(null);
            else requestAnimationFrame(check);
          };
          requestAnimationFrame(check);
        }, 500);
      }, 80);
    JS

    assert elapsed, "the resized chart was never redrawn"
    assert_operator elapsed, :<, 700, "the resized chart waited for the removed sidebar's transition (#{elapsed.round} ms)"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  # A Sankey's bars have a set width; stretched with the drawing they thickened
  # or thinned during the animation and snapped back at the end.
  test "a Sankey's bars keep their width while a sidebar animates" do
    sankey = "#main [data-controller~='sankey-chart']"
    assert_selector "#{sankey} svg path[data-settled-resize-keep-width]"
    page.execute_script(<<~JS)
      window.__bars = []; window.__sampling = true;
      const afterPaint = (fn) => requestAnimationFrame(() => setTimeout(fn, 0));
      const sample = () => {
        const bar = document.querySelector("#{sankey} svg path[data-settled-resize-keep-width]");
        if (bar) window.__bars.push(Math.round(bar.getBoundingClientRect().width * 10) / 10);
        if (window.__sampling) afterPaint(sample);
      };
      sample();
    JS
    before = net_worth_width
    toggle_left_sidebar
    wait_until_settled(changed_from: before)
    page.execute_script("window.__sampling = false")

    widths = page.evaluate_script("window.__bars")
    assert_operator widths.size, :>, 3, "too few frames sampled"
    assert_operator widths.max - widths.min, :<=, 1, "a Sankey bar changed width during the animation: #{widths.uniq.inspect}"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  test "the spending chart's dots stay round while a sidebar animates" do
    spending = "#main [data-controller~='spending-chart']"
    assert_selector "#{spending} svg circle"
    page.execute_script(<<~JS)
      window.__dots = []; window.__sampling = true;
      const afterPaint = (fn) => requestAnimationFrame(() => setTimeout(fn, 0));
      const sample = () => {
        const dot = document.querySelector("#{spending} svg circle");
        if (dot) { const r = dot.getBoundingClientRect(); window.__dots.push(Math.round((r.width - r.height) * 10) / 10); }
        if (window.__sampling) afterPaint(sample);
      };
      sample();
    JS
    before = net_worth_width
    toggle_left_sidebar
    wait_until_settled(changed_from: before)
    page.execute_script("window.__sampling = false")

    skews = page.evaluate_script("window.__dots")
    assert_operator skews.size, :>, 3, "too few frames sampled"
    assert skews.all? { |skew| skew.abs <= 1 }, "a dot turned oval during the animation (width - height): #{skews.uniq.inspect}"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  # Margins are fixed in pixels (a Sankey's 16px extent, the spending chart's
  # axis column): stretched with the drawing, what sits at the edges drifted
  # away from or towards them and jumped back at the end.
  test "bars, dots and labels keep their distance from the chart's edges, and links stay on their bars, while a sidebar animates" do
    sankey = "#main [data-controller~='sankey-chart']"
    spending = "#main [data-controller~='spending-chart']"
    assert_selector "#{sankey} svg path[data-settled-resize-keep-width]"
    assert_selector "#{spending} svg circle"
    page.execute_script(<<~JS)
      window.__gaps = []; window.__sampling = true;
      const afterPaint = (fn) => requestAnimationFrame(() => setTimeout(fn, 0));
      const sample = () => {
        // The chart's drawing, not an icon's svg beside it.
        const sankeySvg = document.querySelector("#{sankey} svg path[data-settled-resize-keep-width]").ownerSVGElement;
        const bars = Array.from(sankeySvg.querySelectorAll("path[data-settled-resize-keep-width]")).map((b) => b.getBoundingClientRect());
        const box = sankeySvg.getBoundingClientRect();
        const spendingSvg = document.querySelector("#{spending} svg circle").ownerSVGElement;
        const sbox = spendingSvg.getBoundingClientRect();
        const label = spendingSvg.querySelector("text[data-settled-resize-edge='right']")?.getBoundingClientRect();
        const dot = spendingSvg.querySelector("circle")?.getBoundingClientRect();
        // The links leaving the leftmost bars start on their right edge, and
        // the label beside those bars keeps its distance from it. Picked as
        // drawn, then followed.
        const leftmost = Math.min(...bars.map((b) => b.left));
        const firstColumn = bars.filter((b) => Math.abs(b.left - leftmost) < 1);
        const columnRight = Math.max(...firstColumn.map((b) => b.right));
        if (!window.__followed || !window.__followed.svg.isConnected || window.__followed.svg !== sankeySvg) {
          window.__followed = {
            svg: sankeySvg,
            links: Array.from(sankeySvg.querySelectorAll("path.sankey-link")).filter((l) => Math.abs(l.getBoundingClientRect().left - columnRight) < 2),
            label: Array.from(sankeySvg.querySelectorAll("text")).find((t) => { const r = t.getBoundingClientRect(); return r.left > columnRight && r.left - columnRight < 20; }),
          };
        }
        const joined = window.__followed.links.map((l) => l.getBoundingClientRect());
        const beside = window.__followed.label?.getBoundingClientRect();
        window.__gaps.push([
          leftmost - box.left,
          box.right - Math.max(...bars.map((b) => b.right)),
          label ? sbox.right - label.right : null,
          // A dot inside the plot moves with it: its place along the plot (the
          // chart's 4px and 48px margins aside), in thousandths, holds instead.
          dot ? (dot.left + dot.width / 2 - sbox.left - 4) / (sbox.width - 52) * 1000 : null,
          joined.length ? Math.max(...joined.map((l) => Math.abs(l.left - columnRight))) : null,
          beside ? beside.left - columnRight : null,
        ].map((v) => v === null ? null : Math.round(v)));
        if (window.__sampling) afterPaint(sample);
      };
      sample();
    JS
    before = net_worth_width
    toggle_left_sidebar
    wait_until_settled(changed_from: before)
    page.execute_script("window.__sampling = false")

    gaps = page.evaluate_script("window.__gaps")
    assert_operator gaps.size, :>, 3, "too few frames sampled"
    names = [ "Sankey left bar", "Sankey right bar", "spending axis label", "spending dot (place along the plot)", "Sankey links' start (from their bar)", "Sankey label (from its bar)" ]
    assert gaps.all? { |frame| frame[4] && frame[5] }, "no link or label beside the Sankey's first column: #{gaps.first.inspect}"
    moved = gaps.transpose.each_with_index.filter_map do |values, i|
      values = values.compact
      "#{names[i]}: #{values.inspect}" if values.any? && values.max - values.min > (i == 3 ? 3 : 1)
    end
    assert_empty moved, "moved against the chart's edges during the animation"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  # The Sankey drops its subcategory column below 640px. Stretching a drawing
  # across that width would show the wrong columns until the animation ends
  # (a squeezed column, or one that pops in at the end): it redraws as the
  # width passes the threshold instead.
  test "a Sankey animated across the subcategory width shows the columns for its width on every frame" do
    family = users(:family_admin).family
    parent = family.categories.create!(name: "Sankey Shopping", color: "#123456")
    child = family.categories.create!(name: "Sankey Groceries", parent: parent)
    account = family.accounts.create!(name: "Sankey checking", currency: "USD", balance: 0, accountable: Depository.new)
    create_transaction(account: account, category: parent, amount: 100, date: Date.current - 2)
    create_transaction(account: account, category: child, amount: 50, date: Date.current - 2)
    page.driver.browser.manage.window.resize_to(1400, 900)
    visit root_path
    sankey = "#main [data-controller~='sankey-chart']"
    assert_selector "#{sankey} svg"
    page.execute_script(%(document.querySelector("#{sankey}").scrollIntoView({ block: "center" })))
    wait_until_settled

    page.execute_script(<<~JS)
      window.__frames = []; window.__sampling = true;
      const afterPaint = (fn) => requestAnimationFrame(() => setTimeout(fn, 0));
      const chart = document.querySelector("#{sankey} [data-sankey-chart-target='chart']") || document.querySelector("#{sankey}");
      const sample = () => {
        const svg = chart.querySelector("svg");
        const width = chart.clientWidth;
        const painted = svg && Math.round(Number(svg.getAttribute("width"))) === Math.round(width);
        // By datum: the subcategory's bar, whether or not its label fits.
        const sub = !!svg && Array.from(svg.querySelectorAll("g > path:not(.sankey-link)")).some((bar) => bar.__data__?.name === "Sankey Groceries");
        if (painted) window.__frames.push([width, sub]);
        if (window.__sampling) afterPaint(sample);
      };
      sample();
    JS
    before = net_worth_width
    toggle_left_sidebar
    wait_until_settled(changed_from: before)
    sleep 0.3
    page.execute_script("window.__sampling = false")

    frames = page.evaluate_script("window.__frames")
    widths = frames.map(&:first)
    assert_operator widths.min, :<, 640, "the chart never went below the threshold: #{widths.uniq.inspect}"
    assert_operator widths.max, :>=, 640, "the chart never reached the threshold: #{widths.uniq.inspect}"
    # Frames from inside the animation, on both sides of the threshold: the
    # first and last frames alone would pass with a chart that only redrew
    # at the end.
    inside = widths.reject { |width| width == widths.min || width == widths.max }
    assert inside.any? { |width| width < 640 }, "no painted frame inside the animation below 640px: #{widths.uniq.inspect}"
    assert inside.any? { |width| width >= 640 }, "no painted frame inside the animation at 640px or more: #{widths.uniq.inspect}"
    wrong = frames.reject { |width, sub| (width >= 640) == sub }
    assert_empty wrong, "frames showing the wrong columns for their width (width, subcategory shown): #{wrong.uniq.inspect}"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  # The spending chart's day axis spans the whole month on wide screens and
  # the days so far on narrow ones. A stretched drawing kept the other span
  # until the resize settled.
  test "the spending chart redraws at once when a resize crosses its narrow-screen width" do
    spending = "#main [data-controller~='spending-chart']"
    page.driver.browser.manage.window.resize_to(700, 900)
    assert_selector "#{spending} svg circle"
    page.document.synchronize(10) do
      settled = page.evaluate_script(%((() => { const e = document.querySelector(#{spending.to_json}); const svg = e.querySelector("svg"); return !!svg && Number(svg.getAttribute("width")) === e.clientWidth && !svg.hasAttribute("preserveAspectRatio") })()))
      raise Capybara::ExpectationNotMet, "the spending chart has not settled" unless settled
    end
    page.execute_script(<<~JS)
      window.__crossed = null; window.__drawn = null;
      const element = document.querySelector(#{spending.to_json});
      const narrow = window.matchMedia("(min-width: 640px)");
      narrow.addEventListener("change", () => { window.__crossed ??= performance.now(); }, { once: true });
      new MutationObserver((mutations) => {
        if (window.__crossed !== null && window.__drawn === null && mutations.some((m) => Array.from(m.addedNodes).some((n) => n.nodeName === "svg"))) window.__drawn = performance.now();
      }).observe(element, { childList: true });
    JS
    page.driver.browser.manage.window.resize_to(600, 900)

    times = nil
    page.document.synchronize(10) do
      times = page.evaluate_script("({ crossed: window.__crossed, drawn: window.__drawn })")
      raise Capybara::ExpectationNotMet, "no redraw after crossing: #{times.inspect}" unless times["crossed"] && times["drawn"]
    end
    # A settle waits 150ms after the last resize; a layout change draws in the
    # same frame.
    assert_operator times["drawn"] - times["crossed"], :<, 100, "the chart waited to settle before showing the narrow-screen axis: #{times.inspect}"
  ensure
    page.driver.browser.manage.window.resize_to(1100, 900) rescue nil
  end

  # Resizing a sidebar from the keyboard (or resetting it) changes its
  # max-width, which animates too: its end must redraw the chart at once, not
  # a settle delay after the sidebar has stopped.
  test "a sidebar's max-width animation redraws the chart as it ends" do
    result = page.evaluate_async_script(<<~JS)
      const done = arguments[0];
      const chart = document.querySelector("#{NET_WORTH}");
      const sidebar = document.querySelector("[data-app-layout-target='leftSidebar']");
      let ended = null; let drawn = null;
      sidebar.addEventListener("transitionend", (event) => { if (event.propertyName === "max-width") ended ??= performance.now(); });
      new MutationObserver((mutations) => {
        if (ended !== null && drawn === null && mutations.some((m) => Array.from(m.addedNodes).some((n) => n.nodeName === "svg"))) drawn = performance.now();
      }).observe(chart, { childList: true, subtree: true });
      // 60px narrower than it is now, as an arrow key or a reset would.
      const width = Math.round(sidebar.getBoundingClientRect().width) - 60;
      document.querySelector("[data-controller~='sidebar-resize']").style.setProperty("--left-sidebar-width", `${width}px`);
      setTimeout(() => done({ ended, drawn }), 1200);
    JS

    assert result["ended"], "the sidebar's max-width never animated: #{result.inspect}"
    assert result["drawn"], "the chart was not redrawn after the animation: #{result.inspect}"
    assert_operator result["drawn"] - result["ended"], :<, 80, "the chart waited out the settle delay after the sidebar stopped: #{result.inspect}"
  end

  # A height change (a dashboard height preset, a dialog sized to the window)
  # is drawn at once: a vertical stretch would distort the charts' fixed
  # margins and a Sankey's flow widths until the settle.
  test "a chart whose height changes is redrawn at that height at once" do
    result = page.evaluate_async_script(<<~JS)
      const done = arguments[0];
      const element = document.querySelector("#{NET_WORTH}");
      const height = element.clientHeight + 120;
      element.style.height = `${height}px`;
      requestAnimationFrame(() => requestAnimationFrame(() => {
        const svg = element.querySelector("svg");
        done({ height, container: element.clientHeight, svg: Number(svg.getAttribute("height")), viewBox: Number(svg.getAttribute("viewBox").split(/[ ,]+/)[3]), stretched: svg.hasAttribute("preserveAspectRatio") });
      }));
    JS

    assert_equal result["height"], result["container"], "the container didn't take the new height: #{result.inspect}"
    assert_equal result["container"], result["svg"], "not drawn at the new height: #{result.inspect}"
    assert_equal result["container"], result["viewBox"], "drawn at the old height and stretched: #{result.inspect}"
    assert_not result["stretched"], "the drawing is stretched: #{result.inspect}"
  end

  private
    def toggle_left_sidebar
      # The toggle saves the preference first; the test layout has no csrf meta tag.
      page.execute_script(%(if (!document.querySelector("[name='csrf-token']")) { const m = document.createElement("meta"); m.name = "csrf-token"; m.content = "test"; document.head.append(m) }))
      find("[data-action='app-layout#toggleLeftSidebar']").click
    end

    def net_worth_width
      page.evaluate_script(%(document.querySelector(#{NET_WORTH.to_json}).clientWidth))
    end

    # Waits (bounded) until the net worth chart is drawn at its container's
    # size, unstretched, and that size has held for two checks in a row (and,
    # with changed_from, differs from that width).
    def wait_until_settled(changed_from: nil)
      last = nil
      page.document.synchronize(10) do
        state = page.evaluate_script(<<~JS)
          (() => {
            const element = document.querySelector(#{NET_WORTH.to_json});
            const svg = element.querySelector("svg");
            const viewBox = svg && Number(svg.getAttribute("viewBox").split(/[ ,]+/)[2]);
            return { width: element.clientWidth, drawn: !!svg && Number(svg.getAttribute("width")) === element.clientWidth && viewBox === element.clientWidth && !svg.hasAttribute("preserveAspectRatio") };
          })()
        JS
        stable = last && last["width"] == state["width"]
        last = state
        settled = state["drawn"] && stable && (changed_from.nil? || state["width"] != changed_from)
        raise Capybara::ExpectationNotMet, "the chart has not settled: #{state.inspect}" unless settled
      end
    end
end
