require "application_system_test_case"

# Each frame of a sidebar's width animation lays out everything beside it
# again, and a long activity list took most of a frame to lay out, so the
# animation stuttered on account pages. While a sidebar animates (or is
# dragged) the page is marked, and rows off screen skip layout. The mark comes
# off afterwards: left on, the containment would clip the rows' menus.
class SidebarAnimationRowsTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    sign_in users(:family_admin)
  end

  test "activity rows skip layout only while a sidebar animates" do
    page.driver.browser.manage.window.resize_to(1400, 1000)
    visit account_path(accounts(:depository))
    row = "#main [data-controller~='clickable-row']"
    assert_selector row, minimum: 1

    # The toggle saves the preference first; the test layout has no csrf meta tag.
    page.execute_script(%(if (!document.querySelector("[name='csrf-token']")) { const m = document.createElement("meta"); m.name = "csrf-token"; m.content = "test"; document.head.append(m) }))
    assert_equal "visible", page.evaluate_script(%(getComputedStyle(document.querySelector(#{row.to_json})).contentVisibility))

    page.execute_script(<<~JS)
      window.__frames = [];
      const sample = () => {
        window.__frames.push([document.documentElement.hasAttribute("data-layout-animating"), getComputedStyle(document.querySelector(#{row.to_json})).contentVisibility]);
        if (window.__frames.length < 90) requestAnimationFrame(sample);
      };
      requestAnimationFrame(sample);
    JS
    find("[data-action='app-layout#toggleLeftSidebar']").click
    sleep 1.5

    frames = page.evaluate_script("window.__frames")
    marked = frames.select(&:first)
    assert marked.any?, "the page was never marked while the sidebar animated"
    assert marked.all? { |_, visibility| visibility == "auto" }, "rows did not skip layout while the page was marked: #{marked.uniq.inspect}"
    assert_not page.evaluate_script(%(document.documentElement.hasAttribute("data-layout-animating"))), "the mark was left on after the animation"
    assert_equal "visible", page.evaluate_script(%(getComputedStyle(document.querySelector(#{row.to_json})).contentVisibility)), "rows still skip layout after the animation"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  # A drag holds the mark until the pointer is released. A pointer the browser
  # cancels (taking a touch over to scroll), or a second pointerdown during the
  # drag, must not leave it on: rows would keep skipping layout and clip menus.
  test "a cancelled or doubled sidebar drag does not leave the page marked" do
    page.driver.browser.manage.window.resize_to(1400, 1000)
    visit account_path(accounts(:depository))
    handle = "[data-action~='pointerdown->sidebar-resize#startLeft']"
    assert_selector handle, visible: :all

    marks = page.evaluate_script(<<~JS)
      (() => {
        const handle = document.querySelector(#{handle.to_json});
        const marked = () => document.documentElement.hasAttribute("data-layout-animating");
        const down = () => handle.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, cancelable: true, clientX: 300 }));
        down();
        const duringDrag = marked();
        down();
        window.dispatchEvent(new PointerEvent("pointercancel", { bubbles: true }));
        const afterCancel = marked();
        down();
        window.dispatchEvent(new PointerEvent("pointerup", { bubbles: true }));
        return { duringDrag, afterCancel, afterUp: marked() };
      })()
    JS

    assert marks["duringDrag"], "a drag did not mark the page"
    assert_not marks["afterCancel"], "a cancelled drag (after a second pointerdown) left the page marked"
    assert_not marks["afterUp"], "a released drag left the page marked"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  # The fallback size stays on between animations: taken off, the browser
  # would forget each row's remembered size (contain-intrinsic-size: auto) and
  # every toggle would start the rows off screen at the fallback again.
  test "activity rows keep their remembered size between animations" do
    page.driver.browser.manage.window.resize_to(1400, 1000)
    visit account_path(accounts(:depository))
    row = "#main [data-controller~='clickable-row']"
    assert_selector row, minimum: 1

    style = page.evaluate_script(%((() => { const s = getComputedStyle(document.querySelector(#{row.to_json})); return [s.contentVisibility, s.containIntrinsicSize] })()))
    assert_equal [ "visible", "auto 72px" ], style
  end

  # A width committed from the divider's keyboard controls or a double-click
  # animates the sidebar too (its max-width), and lays out the rows each frame
  # like a toggle.
  test "a resize from the keyboard or a double-click marks the page until it stops" do
    page.driver.browser.manage.window.resize_to(1400, 1000)
    visit account_path(accounts(:depository))
    handle = "[data-action~='keydown->sidebar-resize#keyLeft']"
    assert_selector handle, visible: :all

    marks = page.evaluate_async_script(<<~JS)
      const done = arguments[0];
      const handle = document.querySelector(#{handle.to_json});
      const marked = () => document.documentElement.hasAttribute("data-layout-animating");
      handle.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowLeft", bubbles: true }));
      const afterKey = marked();
      setTimeout(() => {
        const keySettled = marked();
        handle.dispatchEvent(new MouseEvent("dblclick", { bubbles: true }));
        const afterReset = marked();
        setTimeout(() => done({ afterKey, keySettled, afterReset, resetSettled: marked() }), 1200);
      }, 1200);
    JS

    assert marks["afterKey"], "a keyboard resize did not mark the page"
    assert_not marks["keySettled"], "the mark was left on after the keyboard resize"
    assert marks["afterReset"], "a double-click reset did not mark the page"
    assert_not marks["resetSettled"], "the mark was left on after the reset"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  # A drag whose button is released outside the window, or whose window loses
  # focus, may never see its pointerup; losing the pointer capture or the focus
  # ends it, so the mark comes off and the next drag can start.
  test "a drag that loses the window's focus or its pointer capture ends" do
    page.driver.browser.manage.window.resize_to(1400, 1000)
    visit account_path(accounts(:depository))
    handle = "[data-action~='pointerdown->sidebar-resize#startLeft']"
    assert_selector handle, visible: :all

    marks = page.evaluate_script(<<~JS)
      (() => {
        const handle = document.querySelector(#{handle.to_json});
        const marked = () => document.documentElement.hasAttribute("data-layout-animating");
        const down = () => handle.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, cancelable: true, clientX: 300 }));
        down();
        const duringDrag = marked();
        window.dispatchEvent(new Event("blur"));
        const afterBlur = marked();
        return { duringDrag, afterBlur };
      })()
    JS

    assert marks["duringDrag"], "a drag did not mark the page"
    assert_not marks["afterBlur"], "the window losing focus left the drag (and the mark) on"

    # A real mouse drag: the handle captures the pointer, and losing that
    # capture (as when the button is released outside the window) ends it.
    mouse = page.driver.browser.action
    # The drag's own pointer id (Chromium gives the mouse 1, Firefox can give 0).
    page.execute_script(%(document.querySelector(#{handle.to_json}).addEventListener("pointerdown", (event) => { window.dragPointerId = event.pointerId }, { once: true })))
    mouse.move_to(find(handle, visible: :all).native).click_and_hold.perform
    pointer_id = Integer(page.evaluate_script("window.dragPointerId"))
    captured = page.evaluate_script(<<~JS)
      (() => {
        const handle = document.querySelector(#{handle.to_json});
        return { captured: handle.hasPointerCapture(#{pointer_id}), marked: document.documentElement.hasAttribute("data-layout-animating") };
      })()
    JS
    assert captured["captured"], "a drag did not capture its pointer"
    assert captured["marked"], "a second drag could not start after the interrupted one"

    page.execute_script(%(document.querySelector(#{handle.to_json}).releasePointerCapture(#{pointer_id})))
    # The capture change is processed with the next pointer event.
    mouse.move_by(4, 0).perform
    assert_selector "html:not([data-layout-animating])", visible: :all
    width = page.evaluate_script(%(document.querySelector("[data-app-layout-target='leftSidebar']").getBoundingClientRect().width))
    mouse.move_by(-60, 0).perform
    assert_equal width, page.evaluate_script(%(document.querySelector("[data-app-layout-target='leftSidebar']").getBoundingClientRect().width)), "the drag kept resizing after losing its pointer capture"
    mouse.release.perform
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  # A split transaction's parent row (created here: no fixture has one).
  test "split parent rows skip layout only while a sidebar animates" do
    entry = create_transaction(amount: 100, name: "Split for the sidebar test", account: accounts(:depository))
    entry.split!([ { name: "Part one", amount: 60, category_id: nil }, { name: "Part two", amount: 40, category_id: nil } ])
    page.driver.browser.manage.window.resize_to(1400, 1000)
    visit account_path(accounts(:depository))
    row = "#main .split-group > div:first-child"
    assert_selector row, minimum: 1
    page.execute_script(%(if (!document.querySelector("[name='csrf-token']")) { const m = document.createElement("meta"); m.name = "csrf-token"; m.content = "test"; document.head.append(m) }))

    page.execute_script(<<~JS)
      window.__frames = [];
      const sample = () => {
        window.__frames.push([document.documentElement.hasAttribute("data-layout-animating"), getComputedStyle(document.querySelector(#{row.to_json})).contentVisibility]);
        if (window.__frames.length < 90) requestAnimationFrame(sample);
      };
      requestAnimationFrame(sample);
    JS
    find("[data-action='app-layout#toggleLeftSidebar']").click
    sleep 1.5

    marked = page.evaluate_script("window.__frames").select(&:first)
    assert marked.any?, "the page was never marked while the sidebar animated"
    assert marked.all? { |_, visibility| visibility == "auto" }, "split parent rows did not skip layout while the page was marked: #{marked.uniq.inspect}"
    assert_equal [ "visible", "auto 72px" ], page.evaluate_script(%((() => { const s = getComputedStyle(document.querySelector(#{row.to_json})); return [s.contentVisibility, s.containIntrinsicSize] })()))
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  # A drag started while a toggle is still animating turns the sidebar's
  # transition off, cancelling it with nothing replacing it: the toggle's
  # mark must come off with it, not linger until its fallback.
  test "a drag that interrupts a toggle leaves no mark once it ends" do
    page.driver.browser.manage.window.resize_to(1400, 1000)
    visit account_path(accounts(:depository))
    page.execute_script(%(if (!document.querySelector("[name='csrf-token']")) { const m = document.createElement("meta"); m.name = "csrf-token"; m.content = "test"; document.head.append(m) }))
    handle = "[data-action~='pointerdown->sidebar-resize#startLeft']"
    assert_selector handle, visible: :all

    marks = page.evaluate_async_script(<<~JS)
      const done = arguments[0];
      const marked = () => document.documentElement.hasAttribute("data-layout-animating");
      const sidebar = document.querySelector("[data-app-layout-target='leftSidebar']");
      let cancelled = false;
      sidebar.addEventListener("transitioncancel", (event) => { if (event.target === sidebar && event.propertyName === "width") cancelled = true; });
      document.querySelector("[data-action='app-layout#toggleLeftSidebar']").click();
      setTimeout(() => {
        const handle = document.querySelector(#{handle.to_json});
        handle.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, cancelable: true, clientX: 300 }));
        // The drag lasts a few frames, so its transition: none takes effect.
        requestAnimationFrame(() => requestAnimationFrame(() => {
          window.dispatchEvent(new PointerEvent("pointerup", { bubbles: true }));
          // Well inside the toggle's 600 ms fallback.
          setTimeout(() => done({ cancelled, afterDrag: marked() }), 200);
        }));
      }, 80);
    JS

    assert marks["cancelled"], "the drag did not cancel the toggle's transition: #{marks.inspect}"
    assert_not marks["afterDrag"], "the toggle's mark stayed on after the drag cancelled its transition"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  # Trades are investment accounts' activity rows.
  test "trade rows skip layout only while a sidebar animates" do
    page.driver.browser.manage.window.resize_to(1400, 1000)
    visit account_path(accounts(:investment))
    row = "#main turbo-frame[id^='trade_'] > div"
    assert_selector row, minimum: 1
    page.execute_script(%(if (!document.querySelector("[name='csrf-token']")) { const m = document.createElement("meta"); m.name = "csrf-token"; m.content = "test"; document.head.append(m) }))

    page.execute_script(<<~JS)
      window.__frames = [];
      const sample = () => {
        window.__frames.push([document.documentElement.hasAttribute("data-layout-animating"), getComputedStyle(document.querySelector(#{row.to_json})).contentVisibility]);
        if (window.__frames.length < 90) requestAnimationFrame(sample);
      };
      requestAnimationFrame(sample);
    JS
    find("[data-action='app-layout#toggleLeftSidebar']").click
    sleep 1.5

    marked = page.evaluate_script("window.__frames").select(&:first)
    assert marked.any?, "the page was never marked while the sidebar animated"
    assert marked.all? { |_, visibility| visibility == "auto" }, "trade rows did not skip layout while the page was marked: #{marked.uniq.inspect}"
    assert_equal [ "visible", "auto 72px" ], page.evaluate_script(%((() => { const s = getComputedStyle(document.querySelector(#{row.to_json})); return [s.contentVisibility, s.containIntrinsicSize] })()))
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  # A stored width differing from the default must not animate the sidebar
  # each time the page loads (a Turbo visit swaps in a new sidebar), which
  # would lay out every row on each frame with nothing marked.
  test "a stored sidebar width applies on a visit without animating" do
    page.driver.browser.manage.window.resize_to(1400, 1000)
    visit account_path(accounts(:depository))
    page.execute_script(%(localStorage.setItem("sure.sidebarWidth.left", "400")))

    page.execute_script(<<~JS)
      window.__runs = [];
      document.addEventListener("transitionrun", (event) => {
        if (event.target.matches?.("[data-app-layout-target='leftSidebar']") && ["width", "max-width"].includes(event.propertyName)) window.__runs.push(event.propertyName);
      }, true);
      document.documentElement.dataset.visitDone = "";
      delete document.documentElement.dataset.visitDone;
      document.addEventListener("turbo:load", () => setTimeout(() => { document.documentElement.dataset.visitDone = "true" }, 700), { once: true });
      Turbo.visit(window.location.href);
    JS
    assert_selector "html[data-visit-done]", visible: :all, wait: 10

    assert_equal "400px", page.evaluate_script(%(getComputedStyle(document.querySelector("[data-app-layout-target='leftSidebar']")).maxWidth))
    assert_equal [], page.evaluate_script("window.__runs"), "the stored width animated the sidebar on the visit"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  # Valuations are activity rows too (they have no clickable-row controller).
  test "valuation rows skip layout only while a sidebar animates" do
    page.driver.browser.manage.window.resize_to(1400, 1000)
    visit account_path(accounts(:depository))
    row = "#main turbo-frame[id^='valuation_'] > div"
    assert_selector row, minimum: 1
    page.execute_script(%(if (!document.querySelector("[name='csrf-token']")) { const m = document.createElement("meta"); m.name = "csrf-token"; m.content = "test"; document.head.append(m) }))

    page.execute_script(<<~JS)
      window.__frames = [];
      const sample = () => {
        window.__frames.push([document.documentElement.hasAttribute("data-layout-animating"), getComputedStyle(document.querySelector(#{row.to_json})).contentVisibility]);
        if (window.__frames.length < 90) requestAnimationFrame(sample);
      };
      requestAnimationFrame(sample);
    JS
    find("[data-action='app-layout#toggleLeftSidebar']").click
    sleep 1.5

    marked = page.evaluate_script("window.__frames").select(&:first)
    assert marked.any?, "the page was never marked while the sidebar animated"
    assert marked.all? { |_, visibility| visibility == "auto" }, "valuation rows did not skip layout while the page was marked: #{marked.uniq.inspect}"
    assert_equal [ "visible", "auto 72px" ], page.evaluate_script(%((() => { const s = getComputedStyle(document.querySelector(#{row.to_json})); return [s.contentVisibility, s.containIntrinsicSize] })()))
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  # A keyboard resize (a max-width transition) and a toggle (a width
  # transition) can run at once; the first to end must not take the mark off
  # while the other is still moving the sidebar.
  test "overlapping width and max-width transitions keep the page marked until both end" do
    page.driver.browser.manage.window.resize_to(1400, 1000)
    visit account_path(accounts(:depository))
    page.execute_script(%(if (!document.querySelector("[name='csrf-token']")) { const m = document.createElement("meta"); m.name = "csrf-token"; m.content = "test"; document.head.append(m) }))
    handle = "[data-action~='keydown->sidebar-resize#keyLeft']"
    assert_selector handle, visible: :all

    marks = page.evaluate_async_script(<<~JS)
      const done = arguments[0];
      const handle = document.querySelector(#{handle.to_json});
      const sidebar = document.querySelector("[data-app-layout-target='leftSidebar']");
      const marked = () => document.documentElement.hasAttribute("data-layout-animating");
      const ended = {};
      // Both properties animate here whatever the layout's own transition
      // classes say, so the overlap happens even where only width animates.
      sidebar.style.transitionProperty = "width, max-width";
      handle.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowLeft", bubbles: true }));
      // Added after the keydown created the mark, so it runs after the mark's
      // own transitionend listener and sees what that left.
      sidebar.addEventListener("transitionend", (event) => {
        if (event.target === sidebar && ["width", "max-width"].includes(event.propertyName) && !(event.propertyName in ended)) ended[event.propertyName] = marked();
      });
      setTimeout(() => {
        document.querySelector("[data-action='app-layout#toggleLeftSidebar']").click();
        setTimeout(() => done({ ended, after: marked() }), 1500);
      }, 80);
    JS

    assert_equal [ "max-width", "width" ], marks["ended"].keys.sort, "both transitions should have run: #{marks.inspect}"
    assert marks["ended"]["max-width"], "the mark came off when the max-width transition ended, with the width one still running"
    assert_not marks["after"], "the mark was left on after both transitions ended"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  # Stimulus reuses the controller when its element connects again, so a drag
  # in progress at disconnect must end, not stay set and block the next one.
  test "a drag in progress when the controller disconnects ends" do
    page.driver.browser.manage.window.resize_to(1400, 1000)
    visit account_path(accounts(:depository))
    handle = "[data-action~='pointerdown->sidebar-resize#startLeft']"
    assert_selector handle, visible: :all

    page.execute_script(<<~JS)
      document.querySelector(#{handle.to_json}).dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, cancelable: true, clientX: 300 }));
      window.__layout = document.querySelector("[data-controller~='sidebar-resize']");
      window.__layout.dataset.controller = window.__layout.dataset.controller.replace("sidebar-resize", "").trim();
    JS
    assert_selector "html:not([data-layout-animating])", visible: :all
    page.execute_script(%(window.__layout.dataset.controller += " sidebar-resize"))
    assert_selector "[data-controller~='sidebar-resize']", visible: :all

    state = page.evaluate_script(<<~JS)
      (() => {
        const before = { cursor: document.body.style.cursor, userSelect: document.body.style.userSelect };
        document.querySelector(#{handle.to_json}).dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, cancelable: true, clientX: 300 }));
        const secondDrag = document.documentElement.hasAttribute("data-layout-animating");
        window.dispatchEvent(new PointerEvent("pointerup", { bubbles: true }));
        return { ...before, secondDrag };
      })()
    JS

    assert_equal "", state["cursor"], "the drag's cursor stayed on after the disconnect"
    assert_equal "", state["userSelect"], "text selection stayed off after the disconnect"
    assert state["secondDrag"], "a new drag could not start after the controller connected again"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  # Toggling the same sidebar again while it moves reverses its transition: the
  # old one is cancelled and a new one runs, which must keep the mark until it
  # ends.
  test "a sidebar toggled again mid-animation keeps the page marked until it stops" do
    page.driver.browser.manage.window.resize_to(1400, 1000)
    visit account_path(accounts(:depository))
    page.execute_script(%(if (!document.querySelector("[name='csrf-token']")) { const m = document.createElement("meta"); m.name = "csrf-token"; m.content = "test"; document.head.append(m) }))

    marks = page.evaluate_async_script(<<~JS)
      const done = arguments[0];
      const toggle = document.querySelector("[data-action='app-layout#toggleLeftSidebar']");
      const marked = () => document.documentElement.hasAttribute("data-layout-animating");
      toggle.click();
      setTimeout(() => {
        toggle.click();
        setTimeout(() => {
          const duringReversal = marked();
          setTimeout(() => done({ duringReversal, after: marked() }), 1200);
        // Well inside the reversed transition, which runs only as long as the
        // first had already run (about 100ms of its 300ms).
        }, 40);
      }, 100);
    JS

    assert marks["duringReversal"], "the reversed animation ran without the mark"
    assert_not marks["after"], "the mark was left on after the reversed animation"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  # Paint containment clips a row's fixed-position menus to the row. A tag
  # picker or menu stays open until a click outside it, so one opened before a
  # drag starts stays open through it: its row is not contained.
  test "a row with an open tag picker is not contained while a sidebar is dragged" do
    page.driver.browser.manage.window.resize_to(1400, 1000)
    visit account_path(accounts(:depository))
    row = "#main [data-controller~='clickable-row']"
    picker = "[data-DS--popover-target='button']"
    assert_selector "#{row} #{picker}", minimum: 1
    page.execute_script(%(document.querySelector(#{row.to_json}).scrollIntoView({ block: "center" })))
    first(:css, "#{row} #{picker}").click
    assert_selector "#{row} #{picker}[aria-expanded='true']"

    styles = page.evaluate_script(<<~JS)
      (() => {
        const handle = document.querySelector("[data-action~='pointerdown->sidebar-resize#startLeft']");
        handle.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, cancelable: true, clientX: 300, pointerId: 1 }));
        const rows = Array.from(document.querySelectorAll(#{row.to_json}));
        const open = rows.find((r) => r.querySelector("#{picker}[aria-expanded='true']"));
        const other = rows.find((r) => r !== open);
        const result = {
          marked: document.documentElement.hasAttribute("data-layout-animating"),
          open: getComputedStyle(open).contentVisibility,
          other: other && getComputedStyle(other).contentVisibility,
        };
        window.dispatchEvent(new PointerEvent("pointerup", { bubbles: true, clientX: 300, pointerId: 1 }));
        return result;
      })()
    JS

    assert styles["marked"], "the drag did not mark the page"
    assert_equal "visible", styles["open"], "the row with an open tag picker was contained (clipping the picker) during the drag"
    assert_equal "auto", styles["other"], "the other rows stopped skipping layout during the drag"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  # The investment activity-label quick-edit opens its own dropdown (not a
  # DS menu), which also stays open until a click outside it: its badge says
  # so (aria-expanded), and its row is not contained either.
  test "a trade row with an open activity-label dropdown is not contained while a sidebar is dragged" do
    page.driver.browser.manage.window.resize_to(1400, 1000)
    visit account_path(accounts(:investment))
    row = "#main turbo-frame[id^='trade_'] > div"
    badge = "button[data-activity-label-quick-edit-target='badge']"
    assert_selector "#{row} #{badge}", minimum: 1
    page.execute_script(%(document.querySelector(#{row.to_json}).scrollIntoView({ block: "center" })))
    first(:css, "#{row} #{badge}").click
    assert_selector "#{row} [data-activity-label-quick-edit-target='dropdown']:not(.hidden)"
    assert_selector "#{row} #{badge}[aria-expanded='true']"

    styles = page.evaluate_script(<<~JS)
      (() => {
        const handle = document.querySelector("[data-action~='pointerdown->sidebar-resize#startLeft']");
        handle.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, cancelable: true, clientX: 300, pointerId: 1 }));
        const rows = Array.from(document.querySelectorAll(#{row.to_json}));
        const open = rows.find((r) => r.querySelector("[data-activity-label-quick-edit-target='dropdown']:not(.hidden)"));
        const other = rows.find((r) => r !== open);
        const result = {
          marked: document.documentElement.hasAttribute("data-layout-animating"),
          open: getComputedStyle(open).contentVisibility,
          other: other && getComputedStyle(other).contentVisibility,
        };
        window.dispatchEvent(new PointerEvent("pointerup", { bubbles: true, clientX: 300, pointerId: 1 }));
        return result;
      })()
    JS

    assert styles["marked"], "the drag did not mark the page"
    assert_equal "visible", styles["open"], "the row with an open activity-label dropdown was contained (clipping it) during the drag"
    assert_equal "auto", styles["other"], "the other rows stopped skipping layout during the drag" if styles["other"]

    # Closing it (a click outside) says so too.
    find("#main h1, #main h2", match: :first).click
    assert_selector "#{row} #{badge}[aria-expanded='false']", minimum: 1
    assert_no_selector "#{row} #{badge}[aria-expanded='true']"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  # Only the pointer that started a drag moves or ends it: a second finger the
  # browser cancels (to scroll) must not end a mouse or stylus drag still held.
  test "another pointer's events neither move nor end a drag" do
    page.driver.browser.manage.window.resize_to(1400, 1000)
    visit account_path(accounts(:depository))
    handle = "[data-action~='pointerdown->sidebar-resize#startLeft']"
    assert_selector handle, visible: :all

    result = page.evaluate_script(<<~JS)
      (() => {
        const handle = document.querySelector(#{handle.to_json});
        const sidebar = document.querySelector("[data-app-layout-target='leftSidebar']");
        const marked = () => document.documentElement.hasAttribute("data-layout-animating");
        const width = () => getComputedStyle(document.querySelector("[data-controller~='sidebar-resize']")).getPropertyValue("--left-sidebar-width");
        const left = sidebar.getBoundingClientRect().left;
        handle.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, cancelable: true, clientX: left + 300, pointerId: 1 }));
        const before = width();
        window.dispatchEvent(new PointerEvent("pointermove", { bubbles: true, clientX: left + 260, pointerId: 2 }));
        const afterOtherMove = width();
        window.dispatchEvent(new PointerEvent("pointercancel", { bubbles: true, pointerId: 2 }));
        window.dispatchEvent(new PointerEvent("pointerup", { bubbles: true, clientX: left + 260, pointerId: 2 }));
        const afterOtherEnd = marked();
        window.dispatchEvent(new PointerEvent("pointermove", { bubbles: true, clientX: left + 280, pointerId: 1 }));
        const afterOwnMove = width();
        window.dispatchEvent(new PointerEvent("pointerup", { bubbles: true, clientX: left + 280, pointerId: 1 }));
        return { before, afterOtherMove, afterOtherEnd, afterOwnMove, afterOwnEnd: marked() };
      })()
    JS

    assert_equal result["before"], result["afterOtherMove"], "another pointer's move resized the sidebar: #{result.inspect}"
    assert result["afterOtherEnd"], "another pointer's cancel or release ended the drag: #{result.inspect}"
    assert_not_equal result["before"], result["afterOwnMove"], "the drag's own pointer stopped resizing after another pointer ended: #{result.inspect}"
    assert_not result["afterOwnEnd"], "the drag's own pointer release did not end it: #{result.inspect}"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  # A release can arrive before the last move's width is laid out. Restoring
  # the sidebar's transitions then animated that last change (max-width) after
  # the drag, laying the rows out on every frame of it.
  test "a drag's last width is laid out before the sidebar's transitions return" do
    page.driver.browser.manage.window.resize_to(1400, 1000)
    visit account_path(accounts(:depository))
    handle = "[data-action~='pointerdown->sidebar-resize#startLeft']"
    assert_selector handle, visible: :all

    runs = page.evaluate_async_script(<<~JS)
      const done = arguments[0];
      const handle = document.querySelector(#{handle.to_json});
      const sidebar = document.querySelector("[data-app-layout-target='leftSidebar']");
      const runs = [];
      sidebar.addEventListener("transitionrun", (event) => { if (event.target === sidebar) runs.push(event.propertyName); });
      const left = sidebar.getBoundingClientRect().left;
      // In one task: no layout between the last move and the release.
      handle.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, cancelable: true, clientX: left + 300, pointerId: 1 }));
      window.dispatchEvent(new PointerEvent("pointermove", { bubbles: true, clientX: left + 240, pointerId: 1 }));
      window.dispatchEvent(new PointerEvent("pointerup", { bubbles: true, clientX: left + 240, pointerId: 1 }));
      setTimeout(() => done(runs), 500);
    JS

    assert_empty runs, "the sidebar animated after the drag ended: #{runs.inspect}"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end
end
