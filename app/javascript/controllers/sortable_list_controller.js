import { Controller } from "@hotwired/stimulus";

// Reorderable list with mouse, touch (hold on the handle) and keyboard
// (Enter/Space to grab, arrow keys to move, release to save). Each item needs
// data-sortable-list-target="item" and data-sortable-list-id. On every change
// the ids are sent as JSON to urlValue, nested under paramValue
// ("a.b" sends { a: { b: [...] } }).
export default class extends Controller {
  static targets = ["item"];

  // Hold delay to require deliberate press-and-hold before activating drag mode.
  // Lists whose whole item reacts to touch (not just a small grip) should raise
  // it so a normal scroll does not start a drag.
  static values = {
    url: String,
    param: String,
    holdDelay: { type: Number, default: 150 },
    // Milliseconds after which an unanswered save counts as failed, so a
    // stalled request cannot hold back every later save. 0 waits forever.
    saveTimeout: { type: Number, default: 0 },
    // The same list rendered more than once on a page (e.g. once per tab)
    // follows a move right away: other sortable lists with the same url and
    // param are reordered too.
    mirrorLists: { type: Boolean, default: false },
    // Where a dragged item lands: "below" inserts it before the first item
    // whose vertical centre is below the pointer (a single column),
    // "nearest" next to the item whose centre is closest (a grid): before it
    // on its upper half, after it on its lower half.
    dropTarget: { type: String, default: "below" },
    // Leave keys pressed on a control inside an item to that control.
    ownKeysOnly: { type: Boolean, default: false },
  };

  connect() {
    this.draggedElement = null;
    this.placeholder = null;
    this.touchStartX = 0;
    this.touchStartY = 0;
    this.currentTouchX = 0;
    this.currentTouchY = 0;
    this.isTouching = false;
    this.keyboardGrabbedElement = null;
    this.holdTimer = null;
    this.holdActivated = false;
  }

  disconnect() {
    this.cancelHold();
  }

  // ===== Mouse Drag Events =====
  dragStart(event) {
    // A drag starting inside a row that is not draggable itself (an image,
    // selected text) is not a reorder.
    if (!event.currentTarget.draggable) return;

    // If a touch interaction is in progress, cancel native drag —
    // use touch events with hold delay instead.
    // This avoids blocking mouse/trackpad drag on touch-capable laptops.
    if (this.isTouching || this.pendingSection) {
      event.preventDefault();
      return;
    }

    this.draggedElement = event.currentTarget;
    this.draggedElement.classList.add("opacity-50");
    this.draggedElement.setAttribute("aria-grabbed", "true");
    event.dataTransfer.effectAllowed = "move";
    // Firefox only starts a drag that carries data. A custom type keeps text
    // fields from accepting the row as a drop.
    event.dataTransfer.setData(
      "application/x-sortable-list-id",
      this.draggedElement.dataset.sortableListId ?? "",
    );
  }

  dragEnd(event) {
    event.currentTarget.classList.remove("opacity-50");
    event.currentTarget.setAttribute("aria-grabbed", "false");
    this.clearPlaceholders();
    this.draggedElement = null;
  }

  // Only a drag that started on one of the items is a reorder; a file or
  // text dragged in from outside is left to the browser.
  dragOver(event) {
    // A drag from another list on the page is not ours to drop.
    if (!this.draggedElement) return;

    event.preventDefault();
    event.dataTransfer.dropEffect = "move";

    this.showDropPosition(event.clientX, event.clientY);
  }

  drop(event) {
    if (!this.draggedElement) return;

    event.preventDefault();
    event.stopPropagation();

    this.moveDraggedTo(event.clientX, event.clientY);
    this.clearPlaceholders();
    this.saveOrder();
  }

  // ===== Touch Events =====
  // A press-and-hold gesture activates drag mode; a plain scroll gesture
  // (finger moves before the hold delay elapses) cancels it.

  touchStart(event) {
    // Find the parent item element from the handle
    const section = event.currentTarget.closest(
      "[data-sortable-list-target='item']",
    );
    if (!section) return;

    // Another controller may switch dragging off for a while, e.g. the
    // dashboard Sankey while its expanded view is open.
    if (section.getAttribute("draggable") === "false") return;

    this.pendingSection = section;
    this.touchStartX = event.touches[0].clientX;
    this.touchStartY = event.touches[0].clientY;
    this.currentTouchX = this.touchStartX;
    this.currentTouchY = this.touchStartY;
    this.holdActivated = false;

    // Prevent text selection while waiting for hold to activate
    section.style.userSelect = "none";
    section.style.webkitUserSelect = "none";

    // Start hold timer
    this.holdTimer = setTimeout(() => {
      this.activateDrag();
    }, this.holdDelayValue);
  }

  activateDrag() {
    if (!this.pendingSection) return;

    this.holdActivated = true;
    this.isTouching = true;
    this.draggedElement = this.pendingSection;
    this.draggedElement.classList.add("opacity-50", "scale-[1.02]");
    this.draggedElement.setAttribute("aria-grabbed", "true");

    // Haptic feedback if available
    if (navigator.vibrate) {
      navigator.vibrate(30);
    }
  }

  touchMove(event) {
    const touchX = event.touches[0].clientX;
    const touchY = event.touches[0].clientY;

    // If hold hasn't activated yet, cancel if user moves too far (scrolling or swiping)
    // Uses Euclidean distance to catch diagonal gestures too
    if (!this.holdActivated) {
      const dx = touchX - this.touchStartX;
      const dy = touchY - this.touchStartY;
      // 10px radius
      if (dx * dx + dy * dy > 100) {
        this.cancelHold();
      }
      return;
    }

    if (!this.isTouching || !this.draggedElement) return;

    event.preventDefault();
    this.currentTouchX = touchX;
    this.currentTouchY = touchY;

    this.showDropPosition(this.currentTouchX, this.currentTouchY);
  }

  touchEnd() {
    this.cancelHold();

    if (!this.holdActivated || !this.isTouching || !this.draggedElement) {
      this.resetTouchState();
      return;
    }

    this.moveDraggedTo(this.currentTouchX, this.currentTouchY);

    this.draggedElement.classList.remove("opacity-50", "scale-[1.02]");
    this.draggedElement.setAttribute("aria-grabbed", "false");
    this.clearPlaceholders();
    this.saveOrder();

    this.resetTouchState();
  }

  touchCancel() {
    this.cancelHold();

    if (this.draggedElement) {
      this.draggedElement.classList.remove("opacity-50", "scale-[1.02]");
      this.draggedElement.setAttribute("aria-grabbed", "false");
    }

    this.clearPlaceholders();
    this.resetTouchState();
  }

  // Belt-and-suspenders alongside the `[-webkit-touch-callout:none]` class:
  // if a long-press context menu/link-preview still fires (e.g. a browser
  // that ignores the CSS property), don't let it interrupt the hold gesture.
  suppressContextMenu(event) {
    if (this.pendingSection || this.isTouching) {
      event.preventDefault();
    }
  }

  cancelHold() {
    if (this.holdTimer) {
      clearTimeout(this.holdTimer);
      this.holdTimer = null;
    }
  }

  resetTouchState() {
    // Restore text selection
    if (this.pendingSection) {
      this.pendingSection.style.userSelect = "";
      this.pendingSection.style.webkitUserSelect = "";
    }
    if (this.draggedElement) {
      this.draggedElement.style.userSelect = "";
      this.draggedElement.style.webkitUserSelect = "";
    }

    this.isTouching = false;
    this.draggedElement = null;
    this.pendingSection = null;
    this.holdActivated = false;
  }

  // ===== Keyboard Navigation =====
  // Bound either on the item itself or on a handle inside it. Focus returns
  // to the bound element after each move.
  handleKeyDown(event) {
    const currentSection = event.currentTarget.closest(
      "[data-sortable-list-target='item']",
    );
    if (!currentSection) return;
    // Keys pressed on a control inside the item (a header button, a widget's
    // own inputs) belong to that control, not to the reorder grab.
    if (this.ownKeysOnlyValue && event.target !== event.currentTarget) return;
    this.keyboardFocusElement = event.currentTarget;

    switch (event.key) {
      case "ArrowUp":
        event.preventDefault();
        if (this.keyboardGrabbedElement === currentSection) {
          this.moveUp(currentSection);
        }
        break;
      case "ArrowDown":
        event.preventDefault();
        if (this.keyboardGrabbedElement === currentSection) {
          this.moveDown(currentSection);
        }
        break;
      case "ArrowLeft":
      case "ArrowRight":
        // Keep the period hotkeys from leaving the page before the new
        // order is saved, which only happens on release.
        if (this.keyboardGrabbedElement) event.preventDefault();
        break;
      case "Enter":
      case " ":
        event.preventDefault();
        this.toggleGrabMode(currentSection);
        break;
      case "Escape":
        if (this.keyboardGrabbedElement) {
          event.preventDefault();
          this.releaseKeyboardGrab();
        }
        break;
    }
  }

  toggleGrabMode(section) {
    if (this.keyboardGrabbedElement === section) {
      this.releaseKeyboardGrab();
    } else {
      this.grabWithKeyboard(section);
    }
  }

  grabWithKeyboard(section) {
    // Release any previously grabbed element
    if (this.keyboardGrabbedElement) {
      this.releaseKeyboardGrab();
    }

    this.keyboardGrabbedElement = section;
    section.setAttribute("aria-grabbed", "true");
    section.classList.add("ring-2", "ring-primary", "ring-offset-2");
  }

  releaseKeyboardGrab() {
    if (this.keyboardGrabbedElement) {
      this.keyboardGrabbedElement.setAttribute("aria-grabbed", "false");
      this.keyboardGrabbedElement.classList.remove(
        "ring-2",
        "ring-primary",
        "ring-offset-2",
      );
      this.keyboardGrabbedElement = null;
      return this.saveOrder();
    }
  }

  // Bound to turbo:before-visit. A visit (e.g. following a link inside the
  // list) replaces the page before a row still held with the keyboard is
  // released, which would drop the move. The row is dropped where it is and
  // the visit waits until the order is saved, so the next page shows it.
  saveBeforeVisit(event) {
    if (!this.keyboardGrabbedElement) return;

    event.preventDefault();
    const { url } = event.detail;
    this.releaseKeyboardGrab().then(() => Turbo.visit(url));
  }

  moveUp(section) {
    const previousSibling = section.previousElementSibling;
    if (previousSibling && this.itemTargets.includes(previousSibling)) {
      this.element.insertBefore(section, previousSibling);
      this.keyboardFocusElement?.focus();
    }
  }

  moveDown(section) {
    const nextSibling = section.nextElementSibling;
    if (nextSibling && this.itemTargets.includes(nextSibling)) {
      this.element.insertBefore(nextSibling, section);
      this.keyboardFocusElement?.focus();
    }
  }

  // ===== Drop Position =====
  // Measures the items before touching any classes, so a drag event does
  // not force an extra layout pass.
  showDropPosition(pointerX, pointerY) {
    const { element, position } = this.dropSlot(pointerX, pointerY);
    this.clearPlaceholders();
    this.showPlaceholder(element, position);
  }

  moveDraggedTo(pointerX, pointerY) {
    const { element, position } = this.dropSlot(pointerX, pointerY);

    if (position === "after") {
      element.after(this.draggedElement);
    } else {
      element.before(this.draggedElement);
    }
  }

  // The item the dragged one lands next to, and on which side.
  dropSlot(pointerX, pointerY) {
    const draggableElements = this.itemTargets.filter(
      (section) => section !== this.draggedElement,
    );

    if (this.dropTargetValue === "nearest") {
      const nearest = this.nearestItem(draggableElements, pointerX, pointerY);
      if (nearest) {
        // The lower half of the closest card drops after it, so a card can
        // also move past the last one.
        const box = nearest.getBoundingClientRect();
        const after = pointerY > box.top + box.height / 2;
        return { element: nearest, position: after ? "after" : "before" };
      }
    } else {
      const below = this.firstItemBelow(draggableElements, pointerY);
      if (below) return { element: below, position: "before" };
    }

    return { element: this.element.lastElementChild, position: "after" };
  }

  firstItemBelow(items, pointerY) {
    return items.reduce(
      (closest, child) => {
        const box = child.getBoundingClientRect();
        const offset = pointerY - box.top - box.height / 2;

        if (offset < 0 && offset > closest.offset) {
          return { offset: offset, element: child };
        }
        return closest;
      },
      { offset: Number.NEGATIVE_INFINITY },
    ).element;
  }

  nearestItem(items, pointerX, pointerY) {
    let closest = null;
    let minDistance = Number.POSITIVE_INFINITY;

    items.forEach((child) => {
      const rect = child.getBoundingClientRect();
      const dx = pointerX - (rect.left + rect.width / 2);
      const dy = pointerY - (rect.top + rect.height / 2);
      const distance = Math.sqrt(dx * dx + dy * dy);

      if (distance < minDistance) {
        minDistance = distance;
        closest = child;
      }
    });

    return closest;
  }

  showPlaceholder(element, position) {
    if (!element) return;

    if (position === "before") {
      element.classList.add("border-t-4", "border-primary");
    } else {
      element.classList.add("border-b-4", "border-primary");
    }
  }

  clearPlaceholders() {
    this.itemTargets.forEach((section) => {
      section.classList.remove(
        "border-t-4",
        "border-b-4",
        "border-primary",
        "border-t-2",
        "border-b-2",
      );
    });
  }

  buildBody(order) {
    return this.paramValue
      .split(".")
      .reduceRight((value, key) => ({ [key]: value }), order);
  }

  // Saves run one at a time. A change made while a save is in flight is sent
  // once it finishes, with the latest order only, so an older request can
  // never land after a newer one and restore an earlier order. Resolves once
  // the queue has sent everything.
  saveOrder() {
    const order = this.itemTargets.map((item) => item.dataset.sortableListId);
    const queue = this.mirrorListsValue ? this.mirrorOrder(order) : this;
    queue.pendingOrder = order;
    if (!queue.saving) queue.savesFinished = queue.flushSaves();
    return queue.savesFinished;
  }

  // Applies the order to the other copies of this list and returns the
  // controller whose queue saves for all copies, so their saves also run one
  // at a time.
  mirrorOrder(order) {
    const lists = [
      ...document.querySelectorAll(`[data-controller~='${this.identifier}']`),
    ].filter(
      (list) =>
        list.dataset.sortableListUrlValue === this.urlValue &&
        list.dataset.sortableListParamValue === this.paramValue,
    );

    lists.forEach((list) => {
      if (list === this.element) return;

      order.forEach((id) => {
        const item = list.querySelector(
          `[data-sortable-list-id='${CSS.escape(id)}']`,
        );
        if (item) list.appendChild(item);
      });
    });

    return (
      this.application.getControllerForElementAndIdentifier(
        lists[0],
        this.identifier,
      ) ?? this
    );
  }

  async flushSaves() {
    this.saving = true;
    while (this.pendingOrder) {
      const order = this.pendingOrder;
      this.pendingOrder = null;
      await this.sendOrder(order);
    }
    this.saving = false;
  }

  async sendOrder(order) {
    // The meta tag is missing when forgery protection is off (e.g. in tests);
    // the server still rejects requests without a valid token when it is on.
    const csrfToken = document.querySelector(
      'meta[name="csrf-token"]',
    )?.content;
    const headers = { "Content-Type": "application/json" };
    if (csrfToken) headers["X-CSRF-Token"] = csrfToken;

    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers,
        body: JSON.stringify(this.buildBody(order)),
        signal:
          this.saveTimeoutValue > 0 && AbortSignal.timeout
            ? AbortSignal.timeout(this.saveTimeoutValue)
            : undefined,
      });

      if (!response.ok) {
        const errorData = await response.json().catch(() => ({}));
        console.error(
          "[Sortable List] Failed to save order:",
          response.status,
          errorData,
        );
        // Show the order that is actually saved instead of the unsaved one,
        // e.g. when the list changed in another tab.
        this.pendingOrder = null;
        Turbo.visit(window.location.href, { action: "replace" });
      }
    } catch (error) {
      console.error("[Sortable List] Network error saving order:", error);
      // A newer order still gets sent; otherwise show what is actually saved.
      if (!this.pendingOrder) {
        Turbo.visit(window.location.href, { action: "replace" });
      }
    }
  }
}
