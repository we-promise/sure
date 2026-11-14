require "application_system_test_case"

# Gestures the shared sortable-list controller must not take for a reorder,
# and what it shows when a new order cannot be saved. Driven on the
# dashboard, whose cards react to drag and touch over their whole area.
class SortableListTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
  end

  test "a pinch zoom on a card does not move it" do
    sign_in @user
    keys = section_keys
    record_saved_section_order

    page.execute_script(<<~JS, keys.first, keys.last)
      const [draggedKey, targetKey] = arguments;
      const dragged = document.querySelector(`section[data-section-key='${draggedKey}']`);
      const target = document.querySelector(`section[data-section-key='${targetKey}']`).getBoundingClientRect();
      const start = dragged.getBoundingClientRect();
      const touch = (identifier, element, clientX, clientY) => new Touch({ identifier, target: element, clientX, clientY });
      const fire = (element, type, touches) =>
        element.dispatchEvent(new TouchEvent(type, { bubbles: true, cancelable: true, touches, changedTouches: touches }));
      const first = touch(1, dragged, start.left + 20, start.top + 20);

      // One finger held on the card past the hold delay, so the drag is on;
      // then the second finger of the pinch lands outside the card.
      fire(dragged, "touchstart", [first]);
      setTimeout(() => {
        const second = touch(2, document.body, 5, 5);
        fire(document.body, "touchstart", [first, second]);
        document.documentElement.dataset.dragAfterPinch = dragged.classList.contains("opacity-50");
        fire(dragged, "touchmove", [touch(1, dragged, target.left + 20, target.bottom - 5), second]);
        fire(dragged, "touchend", []);
        document.documentElement.dataset.pinchDone = "true";
      }, 1000);
    JS

    assert_selector "html[data-pinch-done='true']"
    assert_selector "html[data-drag-after-pinch='false']"
    assert_equal keys, section_keys
    assert_no_selector "section[data-section-key].opacity-50"
    assert_nil page.evaluate_script("document.documentElement.dataset.orderRequests")
  end

  test "dragging selected text inside a card does not move the card" do
    sign_in @user
    keys = section_keys
    record_saved_section_order

    page.execute_script(<<~JS, keys.first, keys.last)
      const [draggedKey, targetKey] = arguments;
      const card = document.querySelector(`section[data-section-key='${draggedKey}']`);
      const target = document.querySelector(`section[data-section-key='${targetKey}']`);
      // The browser starts a text drag on the text node under the pointer.
      const walker = document.createTreeWalker(card, NodeFilter.SHOW_TEXT, {
        acceptNode: (node) => (node.textContent.trim() ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP),
      });
      const text = walker.nextNode();
      const box = target.getBoundingClientRect();
      const point = { clientX: box.left + box.width / 2, clientY: box.bottom - 5 };
      const dataTransfer = new DataTransfer();
      text.dispatchEvent(new DragEvent("dragstart", { bubbles: true, cancelable: true, dataTransfer }));
      target.dispatchEvent(new DragEvent("dragover", { bubbles: true, cancelable: true, dataTransfer, ...point }));
      target.dispatchEvent(new DragEvent("drop", { bubbles: true, cancelable: true, dataTransfer, ...point }));
      text.dispatchEvent(new DragEvent("dragend", { bubbles: true, dataTransfer }));
    JS

    assert_equal keys, section_keys
    assert_nil page.evaluate_script("document.documentElement.dataset.orderRequests")
  end

  test "a card dropped on its own place in the two-column grid stays there" do
    @user.update!(preferences: (@user.preferences || {}).merge("dashboard_two_column" => true))
    page.current_window.resize_to(1800, 1400)
    sign_in @user
    keys = section_keys
    record_saved_section_order

    dropped = page.evaluate_script(<<~JS)
      (() => {
        // A half-width card, so its nearest neighbour sits in the other column.
        const card = [...document.querySelectorAll("section[data-section-key]")]
          .find((section) => section.getBoundingClientRect().width < window.innerWidth / 2);
        if (!card) return null;

        const box = card.getBoundingClientRect();
        const point = { clientX: box.left + box.width / 2, clientY: box.top + box.height / 2 };
        const dataTransfer = new DataTransfer();
        card.dispatchEvent(new DragEvent("dragstart", { bubbles: true, cancelable: true, dataTransfer }));
        card.dispatchEvent(new DragEvent("dragover", { bubbles: true, cancelable: true, dataTransfer, ...point }));
        card.dispatchEvent(new DragEvent("drop", { bubbles: true, cancelable: true, dataTransfer, ...point }));
        card.dispatchEvent(new DragEvent("dragend", { bubbles: true, dataTransfer }));
        return card.dataset.sectionKey;
      })()
    JS

    assert dropped, "expected a half-width card in the two-column grid"
    assert_equal keys, section_keys
    assert_nil page.evaluate_script("document.documentElement.dataset.orderRequests")
  end

  test "an order that cannot be saved goes back and says so without reloading" do
    sign_in @user
    keys = section_keys
    page.execute_script(<<~JS)
      document.body.insertAdjacentHTML("beforeend", "<div id='still-this-page'></div>");
      const originalFetch = window.fetch;
      window.fetch = (url, init) =>
        init?.method === "PATCH" ? Promise.reject(new TypeError("Failed to fetch")) : originalFetch(url, init);
    JS

    find("section[data-section-key='#{keys.first}']").send_keys(:enter)
    page.send_keys(:arrow_down)
    page.send_keys(:enter)

    message = I18n.t("layouts.shared.notification_tray.order_save_failed")
    assert_text message
    assert_selector "#aria-announcer", text: message, visible: :all
    assert_equal keys, section_keys
    assert_selector "#still-this-page", visible: :all
    assert_equal keys.first, page.evaluate_script("document.activeElement.dataset.sectionKey")
  end

  test "a save that fails during a drag puts the order back when the drag ends without a move" do
    sign_in @user
    keys = section_keys
    page.execute_script(<<~JS, keys.first, keys.second)
      const [firstKey, secondKey] = arguments;
      const list = document.querySelector(`section[data-section-key='${firstKey}']`).closest("[data-controller~='sortable-list']");
      const controller = window.Stimulus.getControllerForElementAndIdentifier(list, "sortable-list");
      window.fetch = () => Promise.reject(new TypeError("Failed to fetch"));

      // A drag is still going on when the save of an earlier move fails.
      const first = list.querySelector(`[data-section-key='${firstKey}']`);
      list.querySelector(`[data-section-key='${secondKey}']`).after(first);
      controller.draggedElement = first;
      controller.saveOrder().then(() => {
        document.documentElement.dataset.orderWhileDragging = controller.currentOrder().join(",");
        controller.dragEnd({ currentTarget: first });
        document.documentElement.dataset.dragEnded = "true";
      });
    JS

    assert_selector "html[data-drag-ended='true']"
    moved = [ keys.second, keys.first, *keys.drop(2) ]
    assert_equal moved.join(","), page.evaluate_script("document.documentElement.dataset.orderWhileDragging")
    assert_equal keys, section_keys
  end

  test "a failed save goes back to the order a morph brought in" do
    sign_in @user
    keys = section_keys
    page.execute_script(<<~JS, keys.first, keys.second, keys.third)
      const [firstKey, secondKey, thirdKey] = arguments;
      const list = document.querySelector(`section[data-section-key='${firstKey}']`).closest("[data-controller~='sortable-list']");
      const controller = window.Stimulus.getControllerForElementAndIdentifier(list, "sortable-list");
      const item = (key) => list.querySelector(`[data-section-key='${key}']`);

      // A refresh morph swaps the first two cards; the controller stays.
      item(secondKey).after(item(firstKey));
      document.dispatchEvent(new Event("turbo:morph"));

      window.fetch = () => Promise.reject(new TypeError("Failed to fetch"));
      item(thirdKey).after(item(secondKey));
      controller.saveOrder().then(() => { document.documentElement.dataset.saveDone = "true"; });
    JS

    assert_selector "html[data-save-done='true']"
    assert_equal [ keys.second, keys.first, *keys.drop(2) ], section_keys
  end

  private
    def section_keys
      all("section[data-section-key]").map { |section| section["data-section-key"] }
    end
end
