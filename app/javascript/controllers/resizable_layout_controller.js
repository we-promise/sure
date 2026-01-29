import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["leftSidebar", "rightSidebar", "leftHandle", "rightHandle"];
  static values = {
    userId: Number,
    leftWidth: { type: Number, default: 280 },
    rightWidth: { type: Number, default: 360 },
    leftMin: { type: Number, default: 200 },
    leftMax: { type: Number, default: 400 },
    rightMin: { type: Number, default: 200 },
    rightMax: { type: Number, default: 500 },
  };

  connect() {
    this.isDragging = false;
    this.currentHandle = null;
    this.startX = 0;
    this.startWidth = 0;
    this.saveTimeout = null;

    this.boundMouseMove = this.#handleMouseMove.bind(this);
    this.boundMouseUp = this.#handleMouseUp.bind(this);
    this.boundTouchMove = this.#handleTouchMove.bind(this);
    this.boundTouchEnd = this.#handleTouchEnd.bind(this);

    this.#applyInitialWidths();
  }

  disconnect() {
    this.#cleanup();
  }

  #applyInitialWidths() {
    if (this.hasLeftSidebarTarget) {
      this.leftSidebarTarget.style.width = `${this.leftWidthValue}px`;
    }
    if (this.hasRightSidebarTarget) {
      this.rightSidebarTarget.style.width = `${this.rightWidthValue}px`;
    }
  }

  // Mouse events
  startLeftDrag(event) {
    if (event.button !== 0) return;
    event.preventDefault();
    this.#startDrag("left", event.clientX);
  }

  startRightDrag(event) {
    if (event.button !== 0) return;
    event.preventDefault();
    this.#startDrag("right", event.clientX);
  }

  #startDrag(side, clientX) {
    this.isDragging = true;
    this.currentHandle = side;
    this.startX = clientX;
    this.startWidth =
      side === "left" ? this.leftWidthValue : this.rightWidthValue;

    document.body.style.cursor = "col-resize";
    document.body.style.userSelect = "none";

    document.addEventListener("mousemove", this.boundMouseMove);
    document.addEventListener("mouseup", this.boundMouseUp);

    if (side === "left" && this.hasLeftHandleTarget) {
      this.leftHandleTarget.dataset.dragging = "true";
    } else if (side === "right" && this.hasRightHandleTarget) {
      this.rightHandleTarget.dataset.dragging = "true";
    }
  }

  #handleMouseMove(event) {
    if (!this.isDragging) return;
    this.#updateWidth(event.clientX);
  }

  #handleMouseUp() {
    this.#endDrag();
  }

  // Touch events
  startLeftTouch(event) {
    if (event.touches.length !== 1) return;
    event.preventDefault();
    this.#startTouch("left", event.touches[0].clientX);
  }

  startRightTouch(event) {
    if (event.touches.length !== 1) return;
    event.preventDefault();
    this.#startTouch("right", event.touches[0].clientX);
  }

  #startTouch(side, clientX) {
    this.isDragging = true;
    this.currentHandle = side;
    this.startX = clientX;
    this.startWidth =
      side === "left" ? this.leftWidthValue : this.rightWidthValue;

    document.addEventListener("touchmove", this.boundTouchMove, {
      passive: false,
    });
    document.addEventListener("touchend", this.boundTouchEnd);

    if (side === "left" && this.hasLeftHandleTarget) {
      this.leftHandleTarget.dataset.dragging = "true";
    } else if (side === "right" && this.hasRightHandleTarget) {
      this.rightHandleTarget.dataset.dragging = "true";
    }
  }

  #handleTouchMove(event) {
    if (!this.isDragging || event.touches.length !== 1) return;
    event.preventDefault();
    this.#updateWidth(event.touches[0].clientX);
  }

  #handleTouchEnd() {
    this.#endDrag();
  }

  // Keyboard events
  handleLeftKeydown(event) {
    this.#handleKeydown(event, "left");
  }

  handleRightKeydown(event) {
    this.#handleKeydown(event, "right");
  }

  #handleKeydown(event, side) {
    const step = event.shiftKey ? 20 : 5;
    let delta = 0;

    switch (event.key) {
      case "ArrowLeft":
        delta = side === "left" ? -step : step;
        break;
      case "ArrowRight":
        delta = side === "left" ? step : -step;
        break;
      default:
        return;
    }

    event.preventDefault();

    const currentWidth =
      side === "left" ? this.leftWidthValue : this.rightWidthValue;
    const newWidth = this.#clampWidth(currentWidth + delta, side);

    if (side === "left") {
      this.leftWidthValue = newWidth;
      if (this.hasLeftSidebarTarget) {
        this.leftSidebarTarget.style.width = `${newWidth}px`;
      }
    } else {
      this.rightWidthValue = newWidth;
      if (this.hasRightSidebarTarget) {
        this.rightSidebarTarget.style.width = `${newWidth}px`;
      }
    }

    this.#debouncedSave();
  }

  #updateWidth(clientX) {
    const delta = clientX - this.startX;

    if (this.currentHandle === "left") {
      const newWidth = this.#clampWidth(this.startWidth + delta, "left");
      this.leftWidthValue = newWidth;
      if (this.hasLeftSidebarTarget) {
        this.leftSidebarTarget.style.width = `${newWidth}px`;
      }
    } else {
      // For right sidebar, moving right decreases width
      const newWidth = this.#clampWidth(this.startWidth - delta, "right");
      this.rightWidthValue = newWidth;
      if (this.hasRightSidebarTarget) {
        this.rightSidebarTarget.style.width = `${newWidth}px`;
      }
    }
  }

  #clampWidth(width, side) {
    const min = side === "left" ? this.leftMinValue : this.rightMinValue;
    const max = side === "left" ? this.leftMaxValue : this.rightMaxValue;
    return Math.min(Math.max(width, min), max);
  }

  #endDrag() {
    if (!this.isDragging) return;

    this.isDragging = false;

    document.body.style.cursor = "";
    document.body.style.userSelect = "";

    document.removeEventListener("mousemove", this.boundMouseMove);
    document.removeEventListener("mouseup", this.boundMouseUp);
    document.removeEventListener("touchmove", this.boundTouchMove);
    document.removeEventListener("touchend", this.boundTouchEnd);

    if (this.hasLeftHandleTarget) {
      delete this.leftHandleTarget.dataset.dragging;
    }
    if (this.hasRightHandleTarget) {
      delete this.rightHandleTarget.dataset.dragging;
    }

    this.#debouncedSave();
    this.currentHandle = null;
  }

  #debouncedSave() {
    if (this.saveTimeout) {
      clearTimeout(this.saveTimeout);
    }
    this.saveTimeout = setTimeout(() => {
      this.#saveWidths();
    }, 300);
  }

  #saveWidths() {
    fetch(`/users/${this.userIdValue}`, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "X-CSRF-Token": document.querySelector('[name="csrf-token"]').content,
        Accept: "application/json",
      },
      body: new URLSearchParams({
        "user[sidebar_widths][left_sidebar]": this.leftWidthValue,
        "user[sidebar_widths][right_sidebar]": this.rightWidthValue,
      }).toString(),
    });
  }

  #cleanup() {
    if (this.saveTimeout) {
      clearTimeout(this.saveTimeout);
    }
    document.removeEventListener("mousemove", this.boundMouseMove);
    document.removeEventListener("mouseup", this.boundMouseUp);
    document.removeEventListener("touchmove", this.boundTouchMove);
    document.removeEventListener("touchend", this.boundTouchEnd);
  }
}
