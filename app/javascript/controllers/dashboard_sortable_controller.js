import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["section", "handle"];

  // Hold delay to require deliberate press-and-hold before activating drag mode
  static values = {
    holdDelay: { type: Number, default: 800 },
  };

  connect() {
    this.draggedElement = null;
    this.placeholder = null;
    this.touchStartY = 0;
    this.currentTouchX = 0;
    this.currentTouchY = 0;
    this.isTouching = false;
    this.keyboardGrabbedElement = null;
    this.holdTimer = null;
    this.holdActivated = false;
  }

  // ===== Mouse Drag Events =====
  dragStart(event) {
    // On touch devices, cancel native drag — use touch events with hold delay instead
    if (this.isTouchDevice()) {
      event.preventDefault();
      return;
    }

    this.draggedElement = event.currentTarget;
    this.draggedElement.classList.add("opacity-50");
    this.draggedElement.setAttribute("aria-grabbed", "true");
    event.dataTransfer.effectAllowed = "move";
  }

  isTouchDevice() {
    return "ontouchstart" in window || navigator.maxTouchPoints > 0;
  }

  dragEnd(event) {
    event.currentTarget.classList.remove("opacity-50");
    event.currentTarget.setAttribute("aria-grabbed", "false");
    this.clearPlaceholders();
  }

  dragOver(event) {
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";

    const afterElement = this.getDragAfterElement(event.clientX, event.clientY);
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

    const afterElement = this.getDragAfterElement(event.clientX, event.clientY);
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
  // Touch events are bound to the drag handle only, with a short hold delay
  // to prevent accidental touches.

  touchStart(event) {
    // Find the parent section element from the handle
    const section = event.currentTarget.closest(
      "[data-dashboard-sortable-target='section']",
    );
    if (!section) return;

    // Respect strict draggable="false" which might be set by other controllers (e.g. expand-controller)
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
      if (dx * dx + dy * dy > 100) { // 10px radius
        this.cancelHold();
      }
      return;
    }

    if (!this.isTouching || !this.draggedElement) return;

    event.preventDefault();
    this.currentTouchX = touchX;
    this.currentTouchY = touchY;

    const afterElement = this.getDragAfterElement(this.currentTouchX, this.currentTouchY);
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

    const afterElement = this.getDragAfterElement(this.currentTouchX, this.currentTouchY);
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
  handleKeyDown(event) {
    const currentSection = event.currentTarget;

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
    if (previousSibling?.hasAttribute("data-section-key")) {
      this.element.insertBefore(section, previousSibling);
      section.focus();
    }
  }

  moveDown(section) {
    const nextSibling = section.nextElementSibling;
    if (nextSibling?.hasAttribute("data-section-key")) {
      this.element.insertBefore(nextSibling, section);
      section.focus();
    }
  }

  getDragAfterElement(pointerX, pointerY) {
    const siblings = this.sectionTargets.filter(
      (section) => section !== this.draggedElement,
    );

    if (siblings.length === 0) return null;

    // On 2xl grid (2 columns), filter to sections in the same column as pointer
    const column = this.getSameColumnSiblings(siblings, pointerX);

    // Walk top-to-bottom through gaps between sections.
    // Return value is passed to insertBefore(), so we return the element
    // the dragged section should be placed IN FRONT OF, or null for end.
    for (let i = 0; i < column.length; i++) {
      const rect = column[i].getBoundingClientRect();

      // Pointer is above the first section — insert before it
      if (i === 0 && pointerY < rect.top) {
        return column[0];
      }

      // Crossing line = midpoint of gap between this section and the next
      if (i < column.length - 1) {
        const nextRect = column[i + 1].getBoundingClientRect();
        const crossingLine = (rect.bottom + nextRect.top) / 2;

        // Pointer is above the crossing line — it belongs before the next section
        if (pointerY < crossingLine) return column[i + 1];
      }
    }

    // Pointer is below all crossing lines — append to end
    return null;
  }

  getSameColumnSiblings(siblings, pointerX) {
    if (siblings.length <= 1) return siblings;

    // Check if we're in a multi-column layout by comparing left positions
    const firstRect = siblings[0].getBoundingClientRect();
    const hasMultipleColumns = siblings.some(
      (s) => Math.abs(s.getBoundingClientRect().left - firstRect.left) > 50,
    );

    if (!hasMultipleColumns) return siblings;

    // Filter to siblings in the same column as the pointer
    return siblings.filter((s) => {
      const rect = s.getBoundingClientRect();
      return pointerX >= rect.left && pointerX <= rect.right;
    });
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
    this.sectionTargets.forEach((section) => {
      section.classList.remove(
        "border-t-4",
        "border-b-4",
        "border-primary",
        "border-t-2",
        "border-b-2",
      );
    });
  }

  async saveOrder() {
    const order = this.sectionTargets.map(
      (section) => section.dataset.sectionKey,
    );

    // Safely obtain CSRF token
    const csrfToken = document.querySelector('meta[name="csrf-token"]');
    if (!csrfToken) {
      console.error(
        "[Dashboard Sortable] CSRF token not found. Cannot save section order.",
      );
      return;
    }

    try {
      const response = await fetch("/dashboard/preferences", {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken.content,
        },
        body: JSON.stringify({ preferences: { section_order: order } }),
      });

      if (!response.ok) {
        const errorData = await response.json().catch(() => ({}));
        console.error(
          "[Dashboard Sortable] Failed to save section order:",
          response.status,
          errorData,
        );
      }
    } catch (error) {
      console.error(
        "[Dashboard Sortable] Network error saving section order:",
        error,
      );
    }
  }
}
