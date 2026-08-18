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
    this.touchStartX = 0;
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
    // If a touch interaction is in progress, cancel native drag —
    // use touch events with hold delay instead.
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
  // Touch events are bound to the drag handle only, with a short hold delay
  // to prevent accidental touches.

  touchStart(event) {
    // Find the parent section element from the handle
    const section = event.currentTarget.closest(
      "[data-reports-sortable-target='section']",
    );
    if (!section) return;

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

  getDragAfterElement(y) {
    const draggableElements = [
      ...this.sectionTargets.filter((section) => section !== this.draggedElement),
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
        "[Reports Sortable] CSRF token not found. Cannot save section order.",
      );
      return;
    }

    try {
      const response = await fetch("/reports/update_preferences", {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken.content,
        },
        body: JSON.stringify({ preferences: { reports_section_order: order } }),
      });

      if (!response.ok) {
        const errorData = await response.json().catch(() => ({}));
        console.error(
          "[Reports Sortable] Failed to save section order:",
          response.status,
          errorData,
        );
      }
    } catch (error) {
      console.error(
        "[Reports Sortable] Network error saving section order:",
        error,
      );
    }
  }
}
