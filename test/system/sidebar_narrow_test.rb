require "application_system_test_case"

# At the sidebar's narrowest width a group's name must give way to its total:
# a longer name ("Investments", "Other Liabilities") used to push the amount
# out of line with the other groups' amounts or onto a second line.
class SidebarNarrowTest < ApplicationSystemTestCase
  setup { sign_in users(:family_admin) }

  test "at the narrowest sidebar every group's total stays on one line and lines up" do
    page.driver.browser.manage.window.resize_to(1400, 1000)
    visit root_path
    page.execute_script(%(localStorage.setItem("sure.sidebarWidth.left", "240")))
    visit root_path
    assert_left_sidebar_width 240

    totals = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll("#sidebar-scroll [data-group-key] summary p.privacy-sensitive"))
        .filter((p) => p.offsetParent)
        .map((p) => { const r = p.getBoundingClientRect(); return { right: Math.round(r.right), lines: Math.round(r.height / parseFloat(getComputedStyle(p).lineHeight)) } })
    JS

    assert_operator totals.size, :>=, 3
    assert_equal [ 1 ], totals.map { |total| total["lines"] }.uniq, "a group total wrapped"
    assert_equal 1, totals.map { |total| total["right"] }.uniq.size, "the group totals don't line up: #{totals.inspect}"

    names = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll("#sidebar-scroll [data-group-key] summary span.font-medium"))
        .filter((span) => span.offsetParent)
        .map((span) => ({ name: span.textContent.trim(), title: span.title, ellipsis: getComputedStyle(span).textOverflow === "ellipsis", cut: span.scrollWidth > span.clientWidth }))
    JS

    assert_equal totals.size, names.size, "every visible group's name should be checked"
    assert names.all? { |name| name["ellipsis"] && name["title"] == name["name"] }, "group names must truncate with their full name as the title: #{names.inspect}"
    assert names.any? { |name| name["cut"] }, "expected a long group name (e.g. Investments) to be cut at this width: #{names.inspect}"
  ensure
    page.execute_script(%(localStorage.removeItem("sure.sidebarWidth.left")))
  end

  # The full name is in the title, which only a hover shows. A cut name
  # slides once to show its end when its group is tapped or gets keyboard
  # focus; with reduced motion the full name shows instead, with the total
  # moved below it.
  test "a cut group name slides once to show its end when its group is tapped" do
    skip "needs Chrome DevTools touch input" unless page.driver.browser.respond_to?(:execute_cdp)
    narrow_sidebar(touch: true)
    cut = visible_group_names.find { |name| name["cut"] }
    assert cut, "expected a long group name to be cut at this width"
    assert_equal "inline", marquee(cut["name"])["display"], "a cut name must show its ellipsis before it slides"

    tap_group(cut["name"])
    page.document.synchronize { raise Capybara::ExpectationNotMet, "no slide started" unless marquee(cut["name"])["running"] }
    sleep 1.2
    moving = marquee(cut["name"])
    assert_operator moving["shift"], :<, 0, "the name did not slide: #{moving.inspect}"
    assert_equal "clip", moving["textOverflow"], "the ellipsis rides over the moving name"

    page.document.synchronize(6) { raise Capybara::ExpectationNotMet, "still sliding" if marquee(cut["name"])["running"] }
    rested = marquee(cut["name"])
    assert_equal 0, rested["shift"], "the name did not come back"
    assert_equal "", rested["textOverflow"], "the ellipsis did not come back"
    assert_equal "inline", rested["display"], "at rest the name must be inline, or its ellipsis can't show"
    assert visible_group_names.none? { |name| name["totalBelow"] }, "a total moved below its name"
  ensure
    reset_emulation
  end

  test "a name that fits, or a mouse click, does not slide" do
    skip "needs Chrome DevTools touch input" unless page.driver.browser.respond_to?(:execute_cdp)
    narrow_sidebar(touch: true)
    fits = visible_group_names.find { |name| !name["cut"] }
    tap_group(fits["name"])
    sleep 0.3
    assert_not marquee(fits["name"])["running"], "a name that fits slid"

    reset_emulation
    narrow_sidebar
    cut = visible_group_names.find { |name| name["cut"] }
    group_summary(cut["name"]).click
    sleep 0.3
    assert_not marquee(cut["name"])["running"], "a mouse click made the name slide"
  ensure
    reset_emulation
  end

  test "a cut group name slides while its group has keyboard focus" do
    narrow_sidebar
    cut = visible_group_names.find { |name| name["cut"] }
    assert cut, "expected a long group name to be cut at this width"
    page.execute_script(<<~JS, cut["name"])
      Array.from(document.querySelectorAll("#sidebar-scroll [data-group-key] summary"))
        .find((s) => s.offsetParent && s.querySelector("span.font-medium").textContent.trim() === arguments[0])
        .focus({ focusVisible: true });
    JS

    page.document.synchronize { raise Capybara::ExpectationNotMet, "no slide on keyboard focus" unless marquee(cut["name"])["running"] }
  ensure
    page.execute_script(%(localStorage.removeItem("sure.sidebarWidth.left"))) rescue nil
  end

  test "with reduced motion on a touch screen a long group name shows in full and its total moves below it" do
    skip "needs Chrome DevTools touch emulation" unless page.driver.browser.respond_to?(:execute_cdp)
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-reduced-motion", value: "reduce" } ])
    narrow_sidebar(touch: true)

    names = visible_group_names
    assert names.none? { |name| name["cut"] }, "a group name is still cut: #{names.inspect}"
    assert names.any? { |name| name["totalBelow"] }, "no long group name moved its total below it: #{names.inspect}"
    assert_equal [ 1 ], names.map { |name| name["totalLines"] }.uniq, "a group total wrapped"
    assert_equal 1, names.map { |name| name["totalRight"] }.uniq.size, "the group totals don't line up on the right: #{names.inspect}"

    tap_group(names.find { |name| name["totalBelow"] }["name"])
    sleep 0.3
    assert names.none? { |name| marquee(name["name"])["running"] }, "a name slid with reduced motion"
  ensure
    reset_emulation
  end

  private
    def narrow_sidebar(touch: false)
      page.driver.browser.manage.window.resize_to(1400, 1000)
      page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true, maxTouchPoints: 1) if touch
      visit root_path
      page.execute_script(%(localStorage.setItem("sure.sidebarWidth.left", "240")))
      visit root_path
      assert_left_sidebar_width 240
      assert page.evaluate_script(%(matchMedia("(pointer: coarse)").matches)), "the touch emulation did not make the pointer coarse" if touch
    end

    def reset_emulation
      if page.driver.browser.respond_to?(:execute_cdp)
        page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false) rescue nil
        page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: []) rescue nil
      end
      page.execute_script(%(localStorage.removeItem("sure.sidebarWidth.left"))) rescue nil
    end

    def group_summary(name)
      all("#sidebar-scroll [data-group-key] summary").find { |summary| summary.visible? && summary.find("span.font-medium").text.strip == name }
    end

    # A real tap (Chrome DevTools touch input) on the group's name.
    def tap_group(name)
      point = page.evaluate_script(<<~JS, name)
        (() => {
          const span = Array.from(document.querySelectorAll("#sidebar-scroll [data-group-key] summary span.font-medium"))
            .find((s) => s.offsetParent && s.textContent.trim() === arguments[0]);
          const r = span.getBoundingClientRect();
          return [r.left + 10, r.top + r.height / 2];
        })()
      JS
      page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: "touchStart", touchPoints: [ { x: point[0], y: point[1] } ])
      page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: "touchEnd", touchPoints: [])
    end

    def marquee(name)
      page.evaluate_script(<<~JS, name)
        (() => {
          const span = Array.from(document.querySelectorAll("#sidebar-scroll [data-group-key] summary span.font-medium"))
            .find((s) => s.offsetParent && s.textContent.trim() === arguments[0]);
          const text = span.querySelector("[data-sidebar-name-marquee-target='text']");
          return { running: text.getAnimations().some((a) => a.playState === "running"),
                   shift: Math.round(new DOMMatrix(getComputedStyle(text).transform).m41), textOverflow: span.style.textOverflow,
                   display: getComputedStyle(text).display };
        })()
      JS
    end

    def visible_group_names
      page.evaluate_script(<<~JS)
        Array.from(document.querySelectorAll("#sidebar-scroll [data-group-key] summary"))
          .filter((summary) => summary.offsetParent)
          .map((summary) => {
            const span = summary.querySelector("span.font-medium");
            const total = summary.querySelector("p.privacy-sensitive");
            const name = span.getBoundingClientRect(), amount = total.getBoundingClientRect();
            return { name: span.textContent.trim(), cut: span.scrollWidth > span.clientWidth,
                     totalBelow: amount.top >= name.bottom - 2,
                     totalLines: Math.round(amount.height / parseFloat(getComputedStyle(total).lineHeight)),
                     totalRight: Math.round(amount.right) };
          })
      JS
    end

    # The stored width is applied once the sidebar-resize controller connects,
    # and the sidebar then animates to it, so wait until it has settled there.
    def assert_left_sidebar_width(expected)
      page.document.synchronize do
        width = page.evaluate_script(%(Math.round(document.querySelector('[data-sidebar-resize-target="leftSidebar"]').getBoundingClientRect().width)))
        raise Capybara::ExpectationNotMet, "the left sidebar is #{width}px wide, not #{expected}px" unless width == expected
      end
    end
end
