require "application_system_test_case"

# A held item near the top or bottom of the scrolling box scrolls it, so it
# can be dropped past the rows that were on screen. Selenium cannot drive
# native drag and drop, so drags are dispatched DragEvents (as in RulesTest)
# and touches dispatched TouchEvents (as in SortableListTest).
class SortableListAutoscrollTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    page.driver.browser.manage.window.resize_to(1200, 700)
  end

  test "a rule dragged to the bottom edge scrolls the list and can be dropped below what was on screen" do
    rules = 30.times.map do |index|
      @user.family.rules.create!(name: "Rule #{format('%02d', index)}", resource_type: "transaction",
        actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    end
    sign_in @user
    visit rules_path
    first = "[data-sortable-list-id='rule:#{rules.first.id}']"
    assert_selector first

    result = page.evaluate_async_script(<<~JS, first)
      const [sourceSelector] = arguments;
      const done = arguments[arguments.length - 1];
      // The box that scrolls the list (the rules page's layout scrolls an
      // inner column, the dashboard #main).
      const scrollerOf = (element) => {
        for (let node = element.parentElement; node; node = node.parentElement) {
          if (/auto|scroll/.test(getComputedStyle(node).overflowY) && node.scrollHeight > node.clientHeight) return node;
        }
        return document.scrollingElement;
      };
      const source = document.querySelector(sourceSelector);
      const main = scrollerOf(source);
      const box = main.getBoundingClientRect();
      const bottom = Math.min(box.bottom, window.innerHeight);
      const x = box.left + box.width / 2;
      const dataTransfer = new DataTransfer();
      const fire = (element, type, y) => element.dispatchEvent(new DragEvent(type,
        { bubbles: true, cancelable: true, dataTransfer, clientX: x, clientY: y }));
      // A browser sends dragover repeatedly while the pointer is still.
      const holdAt = (y, ms, then) => {
        const timer = setInterval(() => fire(document.elementFromPoint(x, y) || main, "dragover", y), 50);
        setTimeout(() => { clearInterval(timer); then(); }, ms);
      };
      const start = main.scrollTop;
      const visibleRows = Array.from(document.querySelectorAll("[data-sortable-list-id^='rule:']"))
        .filter((row) => row.getBoundingClientRect().bottom <= bottom).length;

      fire(source, "dragstart", box.top + 10);
      holdAt(bottom - 8, 1000, () => {
        const scrolled = main.scrollTop - start;
        const middle = (box.top + bottom) / 2;
        holdAt(middle, 300, () => {
          const settled = main.scrollTop;
          holdAt(middle, 300, () => {
            // Measured before the drop, which moves the rows themselves.
            const stillWhileMiddle = main.scrollTop - settled;
            const target = document.elementFromPoint(x, middle);
            fire(target, "drop", middle);
            fire(source, "dragend", middle);
            done({ scrolled, stillWhileMiddle, visibleRows });
          });
        });
      });
    JS

    assert_operator result["scrolled"], :>, 200, "holding at the bottom edge did not scroll the list: #{result.inspect}"
    assert_equal 0, result["stillWhileMiddle"], "the list kept scrolling with the pointer away from the edges"

    moved_to = nil
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Capybara.default_max_wait_time
    loop do
      moved_to = @user.family.rules.ordered.pluck(:id).index(rules.first.id)
      # The family already has a rule, so the first new one starts at index 1:
      # wait for the index the assertion needs, not just any move.
      break if moved_to >= result["visibleRows"] || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
    assert_operator moved_to, :>=, result["visibleRows"], "the rule was not dropped below the rows that were on screen"
  end

  # The rows move under a pointer that may not move at all; the drop position
  # has to follow them without waiting for the next pointer event.
  test "the drop position follows the rows as the list scrolls under a still pointer" do
    # Tall enough that the pointer at the bottom edge isn't over the dragged
    # (first) row itself, where no drop position shows.
    page.driver.browser.manage.window.resize_to(1200, 1000)
    rules = 30.times.map do |index|
      @user.family.rules.create!(name: "Rule #{format('%02d', index)}", resource_type: "transaction",
        actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    end
    sign_in @user
    visit rules_path
    first = "[data-sortable-list-id='rule:#{rules.first.id}']"
    assert_selector first

    result = page.evaluate_async_script(<<~JS, first)
      const [sourceSelector] = arguments;
      const done = arguments[arguments.length - 1];
      const source = document.querySelector(sourceSelector);
      let main = document.scrollingElement;
      for (let node = source.parentElement; node; node = node.parentElement) {
        if (/auto|scroll/.test(getComputedStyle(node).overflowY) && node.scrollHeight > node.clientHeight) { main = node; break; }
      }
      const box = main.getBoundingClientRect();
      const y = Math.min(box.bottom, window.innerHeight) - 8;
      const x = box.left + box.width / 2;
      const dataTransfer = new DataTransfer();
      const fire = (element, type) => element.dispatchEvent(new DragEvent(type,
        { bubbles: true, cancelable: true, dataTransfer, clientX: x, clientY: y }));
      const marked = () => document.querySelector("[data-sortable-list-target='item'].border-primary");

      fire(source, "dragstart");
      // On the list itself (its dragover handler) and so the page's too.
      fire(source.closest("[data-controller~='sortable-list']"), "dragover");
      const first = marked();
      // No further pointer events: only the scrolling moves the rows.
      setTimeout(() => {
        const now = marked();
        // The slot a fresh pointer event would show at the same point (the
        // first row whose centre is below it, which may sit half a row lower).
        const list = source.closest("[data-controller~='sortable-list']");
        const expected = window.Stimulus.getControllerForElementAndIdentifier(list, "sortable-list").dropSlot(x, y)?.element;
        fire(source, "dragend");
        done({
          firstId: first?.dataset.sortableListId, nowId: now?.dataset.sortableListId,
          expectedId: expected?.dataset.sortableListId
        });
      }, 600);
    JS

    assert result["firstId"], "the first dragover showed no drop position: #{result.inspect}"
    assert_not_equal result["firstId"], result["nowId"], "the drop position stayed on a row that scrolled away"
    assert result["nowId"], "scrolling removed the drop position: #{result.inspect}"
    assert_equal result["expectedId"], result["nowId"], "the drop position is not where the pointer now is: #{result.inspect}"
  end

  test "a card held still by touch at the bottom edge scrolls the page without moving" do
    sign_in @user
    assert_selector "[data-section-key]", minimum: 2

    result = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      const card = document.querySelector("section[data-section-key]");
      let main = document.scrollingElement;
      for (let node = card.parentElement; node; node = node.parentElement) {
        if (/auto|scroll/.test(getComputedStyle(node).overflowY) && node.scrollHeight > node.clientHeight) { main = node; break; }
      }
      const box = main.getBoundingClientRect();
      const y = Math.min(box.bottom, window.innerHeight) - 8;
      const x = box.left + box.width / 2;
      // The touch is dispatched on a card (the second one, scrolled so that
      // its top sits just above the point), at a point in the bottom edge.
      const held = document.querySelectorAll("section[data-section-key]")[1];
      main.scrollTop += held.getBoundingClientRect().top - (y - 30);
      const touches = [ new Touch({ identifier: 1, target: held, clientX: x, clientY: y }) ];
      const before = main.scrollTop;

      held.dispatchEvent(new TouchEvent("touchstart", { bubbles: true, cancelable: true, touches, changedTouches: touches }));
      // Past the 800 ms hold, with no touchmove at all.
      setTimeout(() => {
        const scrolled = main.scrollTop - before;
        held.dispatchEvent(new TouchEvent("touchend", { bubbles: true, cancelable: true, touches: [], changedTouches: touches }));
        done({ scrolled });
      }, 1500);
    JS

    assert_operator result["scrolled"], :>, 50, "a card held still at the edge did not scroll: #{result.inspect}"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  # A list's scrolling box can be moved out of view by the page around it
  # while a drag goes on; with no visible part there is nothing to scroll.
  test "a scrolling box out of view is not scrolled" do
    sign_in @user
    assert_selector "[data-section-key]"

    result = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      import("utils/drag_autoscroll").then(({ default: DragAutoscroll }) => {
        const box = document.createElement("div");
        box.style.cssText = `position: fixed; left: 0; top: ${window.innerHeight + 200}px; width: 300px; height: 200px; overflow-y: auto`;
        box.innerHTML = '<div style="height: 50000px"><span>item</span></div>';
        document.body.append(box);
        // Midway, so a step either way would show.
        box.scrollTop = 20000;
        const start = box.scrollTop;
        const autoscroll = new DragAutoscroll();
        autoscroll.update(box.querySelector("span"), 100, 300);
        setTimeout(() => {
          const scrolled = box.scrollTop - start;
          autoscroll.stop();
          box.remove();
          done({ scrolled });
        }, 200);
      });
    JS

    assert_equal 0, result["scrolled"], "a box below the viewport was scrolled"
  end

  # The pointer may be held beside the scrolling box, over a sidebar next to
  # it, at the height of its bottom edge: that is not near the edge.
  test "a card dragged beside the scrolling box at its bottom edge's height does not scroll it" do
    sign_in @user
    assert_selector "[data-section-key]", minimum: 2

    result = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      const card = document.querySelector("section[data-section-key]");
      const main = document.getElementById("main");
      const box = main.getBoundingClientRect();
      const y = Math.min(box.bottom, window.innerHeight) - 8;
      const beside = box.left / 2;
      const inside = box.left + box.width / 2;
      const dataTransfer = new DataTransfer();
      const fire = (element, type, x) => element.dispatchEvent(new DragEvent(type,
        { bubbles: true, cancelable: true, dataTransfer, clientX: x, clientY: y }));
      const holdAt = (x, ms, then) => {
        const timer = setInterval(() => fire(document.elementFromPoint(x, y) || document.body, "dragover", x), 50);
        setTimeout(() => { clearInterval(timer); then(); }, ms);
      };

      fire(card, "dragstart", inside);
      const start = main.scrollTop;
      holdAt(beside, 600, () => {
        const besideScrolled = main.scrollTop - start;
        const insideStart = main.scrollTop;
        holdAt(inside, 600, () => {
          const insideScrolled = main.scrollTop - insideStart;
          fire(card, "dragend", inside);
          done({ besideScrolled, insideScrolled, mainLeft: box.left });
        });
      });
    JS

    assert_operator result["mainLeft"], :>, 0, "nothing beside #main to hold the pointer over: #{result.inspect}"
    assert_equal 0, result["besideScrolled"], "holding beside #main at its bottom edge's height scrolled it"
    assert_operator result["insideScrolled"], :>, 50, "holding over #main at its bottom edge did not scroll it: #{result.inspect}"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  # A finger settles a few pixels from where it landed during the hold; the
  # autoscroll starts from where it rests, here just inside the edge zone.
  test "a card held still after a small drift into the edge zone scrolls from where the finger rests" do
    sign_in @user
    assert_selector "[data-section-key]", minimum: 2

    result = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      const card = document.querySelectorAll("section[data-section-key]")[1];
      let main = document.scrollingElement;
      for (let node = card.parentElement; node; node = node.parentElement) {
        if (/auto|scroll/.test(getComputedStyle(node).overflowY) && node.scrollHeight > node.clientHeight) { main = node; break; }
      }
      const box = main.getBoundingClientRect();
      const bottom = Math.min(box.bottom, window.innerHeight);
      const x = box.left + box.width / 2;
      // 85px from the bottom is outside the 80px zone; 8px later it is inside.
      const landed = bottom - 85;
      main.scrollTop += card.getBoundingClientRect().top - (landed - 30);
      const at = (y) => [ new Touch({ identifier: 1, target: card, clientX: x, clientY: y }) ];
      const before = main.scrollTop;

      card.dispatchEvent(new TouchEvent("touchstart", { bubbles: true, cancelable: true, touches: at(landed), changedTouches: at(landed) }));
      setTimeout(() => card.dispatchEvent(new TouchEvent("touchmove", { bubbles: true, cancelable: true, touches: at(landed + 8), changedTouches: at(landed + 8) })), 200);
      // Past the 800 ms hold, with no move after the drift.
      setTimeout(() => {
        const scrolled = main.scrollTop - before;
        card.dispatchEvent(new TouchEvent("touchend", { bubbles: true, cancelable: true, touches: [], changedTouches: at(landed + 8) }));
        done({ scrolled });
      }, 1500);
    JS

    assert_operator result["scrolled"], :>, 30, "a finger resting inside the edge zone after a drift did not scroll: #{result.inspect}"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  # Pinch zoom or an on-screen keyboard can leave less on screen than the
  # layout viewport; the edges are those of what is visible.
  test "the edges are those of the visible part of the page" do
    sign_in @user
    assert_selector "[data-section-key]"

    result = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      import("utils/drag_autoscroll").then(({ default: DragAutoscroll }) => {
        const box = document.createElement("div");
        box.style.cssText = "position: fixed; inset: 0; overflow-y: auto";
        box.innerHTML = '<div style="height: 50000px"><span>item</span></div>';
        document.body.append(box);
        box.scrollTop = 20000;
        const start = box.scrollTop;
        // Only the top 300px are on screen (as with a keyboard up).
        Object.defineProperty(window, "visualViewport", { configurable: true,
          value: { offsetTop: 0, offsetLeft: 0, height: 300, width: window.innerWidth } });
        const autoscroll = new DragAutoscroll();
        autoscroll.update(box.querySelector("span"), 100, 292);
        setTimeout(() => {
          const scrolled = box.scrollTop - start;
          autoscroll.stop();
          delete window.visualViewport;
          box.remove();
          done({ scrolled, innerHeight: window.innerHeight });
        }, 200);
      });
    JS

    assert_operator result["innerHeight"], :>, 400, "the layout viewport is too short for this check"
    assert_operator result["scrolled"], :>, 0, "a pointer at the visible bottom edge did not scroll: #{result.inspect}"
  end

  test "a card held by touch near the bottom edge scrolls the page until the finger lifts" do
    sign_in @user
    assert_selector "[data-section-key]", minimum: 2

    result = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      // The box that scrolls the list (the rules page's layout scrolls an
      // inner column, the dashboard #main).
      const scrollerOf = (element) => {
        for (let node = element.parentElement; node; node = node.parentElement) {
          if (/auto|scroll/.test(getComputedStyle(node).overflowY) && node.scrollHeight > node.clientHeight) return node;
        }
        return document.scrollingElement;
      };
      const card = document.querySelector("section[data-section-key]");
      const main = scrollerOf(card);
      const box = main.getBoundingClientRect();
      const bottom = Math.min(box.bottom, window.innerHeight);
      const start = card.getBoundingClientRect();
      const touch = (y) => new Touch({ identifier: 1, target: card, clientX: start.left + 20, clientY: y });
      const fire = (type, touches) =>
        card.dispatchEvent(new TouchEvent(type, { bubbles: true, cancelable: true, touches, changedTouches: touches }));

      fire("touchstart", [touch(start.top + 20)]);
      // Past the dashboard's 800 ms hold, so the card is picked up.
      setTimeout(() => {
        const before = main.scrollTop;
        fire("touchmove", [touch(bottom - 8)]);
        setTimeout(() => {
          const scrolled = main.scrollTop - before;
          fire("touchend", []);
          const lifted = main.scrollTop;
          setTimeout(() => done({ scrolled, afterLift: main.scrollTop - lifted }), 300);
        }, 700);
      }, 1000);
    JS

    assert_operator result["scrolled"], :>, 100, "holding a card at the bottom edge did not scroll: #{result.inspect}"
    assert_operator result["afterLift"].abs, :<=, 20, "the page kept scrolling after the finger lifted"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  test "a rule dragged to the top edge scrolls the list up" do
    first = visit_long_rules_list

    result = page.evaluate_async_script(<<~JS, first)
      const [sourceSelector] = arguments;
      const done = arguments[arguments.length - 1];
      #{SCROLLER_OF}
      const source = document.querySelector(sourceSelector);
      const main = scrollerOf(source);
      main.scrollTop = main.scrollHeight;
      const box = main.getBoundingClientRect();
      const top = Math.max(box.top, 0) + 8;
      const x = box.left + box.width / 2;
      const dataTransfer = new DataTransfer();
      const fire = (element, type, y) => element.dispatchEvent(new DragEvent(type,
        { bubbles: true, cancelable: true, dataTransfer, clientX: x, clientY: y }));
      const start = main.scrollTop;
      // Picked up from the bottom of what is on screen, then held at the top.
      const visible = Array.from(document.querySelectorAll("[data-sortable-list-id^='rule:']"))
        .filter((row) => { const r = row.getBoundingClientRect(); return r.top > box.top && r.bottom < Math.min(box.bottom, window.innerHeight); });
      const dragged = visible[visible.length - 1];
      fire(dragged, "dragstart", top);
      const timer = setInterval(() => fire(document.elementFromPoint(x, top) || main, "dragover", top), 50);
      setTimeout(() => {
        clearInterval(timer);
        const scrolled = main.scrollTop - start;
        fire(dragged, "dragend", top);
        done({ scrolled, start });
      }, 800);
    JS

    assert_operator result["start"], :>, 200, "the list did not start scrolled down: #{result.inspect}"
    assert_operator result["scrolled"], :<, -100, "holding at the top edge did not scroll the list up: #{result.inspect}"
  end

  # Releasing a mouse drag with the pointer still in the edge zone sends no
  # further dragover; the scrolling must stop with the drag.
  test "a mouse drag released at the edge stops scrolling" do
    first = visit_long_rules_list

    result = page.evaluate_async_script(<<~JS, first)
      const [sourceSelector] = arguments;
      const done = arguments[arguments.length - 1];
      #{SCROLLER_OF}
      const source = document.querySelector(sourceSelector);
      const main = scrollerOf(source);
      const box = main.getBoundingClientRect();
      const y = Math.min(box.bottom, window.innerHeight) - 8;
      const x = box.left + box.width / 2;
      const dataTransfer = new DataTransfer();
      const fire = (element, type) => element.dispatchEvent(new DragEvent(type,
        { bubbles: true, cancelable: true, dataTransfer, clientX: x, clientY: y }));
      const start = main.scrollTop;
      fire(source, "dragstart");
      fire(document.elementFromPoint(x, y) || main, "dragover");
      setTimeout(() => {
        fire(source, "dragend");
        const released = main.scrollTop;
        setTimeout(() => done({ scrolled: released - start, afterRelease: main.scrollTop - released }), 400);
      }, 400);
    JS

    assert_operator result["scrolled"], :>, 50, "the drag did not scroll before the release: #{result.inspect}"
    assert_operator result["afterRelease"].abs, :<=, 20, "the list kept scrolling after the drag was released: #{result.inspect}"
  end

  # The browser cancels a touch it takes over; the scrolling must stop with it.
  test "a touch drag the browser cancels at the edge stops scrolling" do
    sign_in @user
    assert_selector "[data-section-key]", minimum: 2

    result = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      #{SCROLLER_OF}
      const card = document.querySelectorAll("section[data-section-key]")[1];
      const main = scrollerOf(card);
      const box = main.getBoundingClientRect();
      const y = Math.min(box.bottom, window.innerHeight) - 8;
      const x = box.left + box.width / 2;
      main.scrollTop += card.getBoundingClientRect().top - (y - 30);
      const touches = [ new Touch({ identifier: 1, target: card, clientX: x, clientY: y }) ];
      const fire = (type, list) => card.dispatchEvent(new TouchEvent(type, { bubbles: true, cancelable: true, touches: list, changedTouches: touches }));
      const start = main.scrollTop;
      fire("touchstart", touches);
      // Past the 800 ms hold, scrolling; then the browser cancels the touch.
      setTimeout(() => {
        fire("touchcancel", []);
        const cancelled = main.scrollTop;
        setTimeout(() => done({ scrolled: cancelled - start, afterCancel: main.scrollTop - cancelled }), 400);
      }, 1300);
    JS

    assert_operator result["scrolled"], :>, 30, "the held card did not scroll before the cancel: #{result.inspect}"
    assert_operator result["afterCancel"].abs, :<=, 20, "the page kept scrolling after the touch was cancelled: #{result.inspect}"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  private
    # Rules page with 30 rules; returns the selector of the first new rule.
    def visit_long_rules_list
      rules = 30.times.map do |index|
        @user.family.rules.create!(name: "Rule #{format('%02d', index)}", resource_type: "transaction",
          actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
      end
      sign_in @user
      visit rules_path
      selector = "[data-sortable-list-id='rule:#{rules.first.id}']"
      assert_selector selector
      selector
    end

    # JS defining `scrollerOf(element)`: the box that scrolls it.
    SCROLLER_OF = <<~JS.freeze
      const scrollerOf = (element) => {
        for (let node = element.parentElement; node; node = node.parentElement) {
          if (/auto|scroll/.test(getComputedStyle(node).overflowY) && node.scrollHeight > node.clientHeight) return node;
        }
        return document.scrollingElement;
      };
    JS
end
