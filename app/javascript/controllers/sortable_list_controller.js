import { Controller } from "@hotwired/stimulus";

// Reorderable list with mouse, touch (hold on the handle) and keyboard
// (Enter/Space to grab, arrow keys to move, release to save). Each item needs
// data-sortable-list-target="item" and data-sortable-list-id. On every change
// the ids are sent as JSON to urlValue, nested under paramValue
// ("a.b" sends { a: { b: [...] } }).
export default class extends Controller {
  static targets = ["item", "handle"];

  // Hold delay to require deliberate press-and-hold before activating drag mode.
  // Lists whose whole item reacts to touch (not just a small grip) should raise
  // it so a normal scroll does not start a drag.
  static values = {
    url: String,
    param: String,
    holdDelay: { type: Number, default: 150 },
  };

  connect() {
    this.draggedElement = null;
    this.placeholder = null;
    this.touchStartX = 0;
    this.touchStartY = 0;
    this.currentTouchY = 0;
    this.isTouching = false;
    this.keyboardGrabbedElement = null;
    this.holdTimer = null;
    this.holdActivated = false;
  }

  // ===== Mouse Drag Events =====
  dragStart(event) {
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
  }

  dragEnd(event) {
    event.currentTarget.classList.remove("opacity-50");
    event.currentTarget.setAttribute("aria-grabbed", "false");
    this.clearPlaceholders();
  }

  dragOver(event) {
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";

    const afterElement = this.getDragAfterElement(event.clientY);
    const container = this.element;

    this.clearPlaceholders();

    if (afterElement == null) {
      this.showPlaceholder(container.lastElementChild, "after");
    } else {
      this.showPlaceholder(afterElement, "before");
    }
  }

  drop(event) {
    event.preventDefault();
    event.stopPropagation();

    const afterElement = this.getDragAfterElement(event.clientY);
    const container = this.element;

    if (afterElement == null) {
      container.appendChild(this.draggedElement);
    } else {
      container.insertBefore(this.draggedElement, afterElement);
    }

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

    this.pendingSection = section;
    this.touchStartX = event.touches[0].clientX;
    this.touchStartY = event.touches[0].clientY;
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
      if (dx * dx + dy * dy > 100) { // 10px radius
        this.cancelHold();
      }
      return;
    }

    if (!this.isTouching || !this.draggedElement) return;

    event.preventDefault();
    this.currentTouchY = touchY;

    const afterElement = this.getDragAfterElement(this.currentTouchY);
    this.clearPlaceholders();

    if (afterElement == null) {
      this.showPlaceholder(this.element.lastElementChild, "after");
    } else {
      this.showPlaceholder(afterElement, "before");
    }
  }

  touchEnd() {
    this.cancelHold();

    if (!this.holdActivated || !this.isTouching || !this.draggedElement) {
      this.resetTouchState();
      return;
    }

    const afterElement = this.getDragAfterElement(this.currentTouchY);
    const container = this.element;

    if (afterElement == null) {
      container.appendChild(this.draggedElement);
    } else {
      container.insertBefore(this.draggedElement, afterElement);
    }

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
      this.saveOrder();
    }
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

  getDragAfterElement(y) {
    const draggableElements = [
      ...this.itemTargets.filter((section) => section !== this.draggedElement),
    ];

    return draggableElements.reduce(
      (closest, child) => {
        const box = child.getBoundingClientRect();
        const offset = y - box.top - box.height / 2;

        if (offset < 0 && offset > closest.offset) {
          return { offset: offset, element: child };
        }
        return closest;
      },
      { offset: Number.NEGATIVE_INFINITY },
    ).element;
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
  // never land after a newer one and restore an earlier order.
  saveOrder() {
    this.pendingOrder = this.itemTargets.map(
      (item) => item.dataset.sortableListId,
    );
    if (!this.saving) this.flushSaves();
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
