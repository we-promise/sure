import {
  autoUpdate,
  computePosition,
  flip,
  offset,
  shift,
} from "@floating-ui/dom";
import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["tooltip"];
  static values = {
    placement: { type: String, default: "top" },
    offset: { type: Number, default: 10 },
    crossAxis: { type: Number, default: 0 },
  };

  connect() {
    this._cleanup = null;
    this.boundUpdate = this.update.bind(this);
    this.addEventListeners();
  }

  disconnect() {
    this.removeEventListeners();
    this.stopAutoUpdate();
  }

  addEventListeners() {
    this.element.addEventListener("mouseenter", this.show);
    this.element.addEventListener("mouseleave", this.hide);
    // Keyboard parity: keyboard users hit the trigger via Tab + focus,
    // not hover. Without these the tooltip never appears for them.
    this.element.addEventListener("focusin", this.show);
    this.element.addEventListener("focusout", this.hide);
    // Esc-to-dismiss matches the WAI-ARIA Authoring Practices for the
    // tooltip pattern.
    this.element.addEventListener("keydown", this.handleKeydown);
  }

  removeEventListeners() {
    this.element.removeEventListener("mouseenter", this.show);
    this.element.removeEventListener("mouseleave", this.hide);
    this.element.removeEventListener("focusin", this.show);
    this.element.removeEventListener("focusout", this.hide);
    this.element.removeEventListener("keydown", this.handleKeydown);
  }

  show = () => {
    this.tooltipTarget.classList.remove("hidden");
    this.startAutoUpdate();
    this.update();
  };

  hide = () => {
    this.tooltipTarget.classList.add("hidden");
    this.stopAutoUpdate();
  };

  handleKeydown = (event) => {
    if (event.key === "Escape" && !this.tooltipTarget.classList.contains("hidden")) {
      this.hide();
    }
  };

  startAutoUpdate() {
    if (!this._cleanup) {
      const reference = this.element.querySelector("[data-icon]");
      this._cleanup = autoUpdate(
        reference || this.element,
        this.tooltipTarget,
        this.boundUpdate
      );
    }
  }

  stopAutoUpdate() {
    if (this._cleanup) {
      this._cleanup();
      this._cleanup = null;
    }
  }

  update() {
    const reference = this.element.querySelector("[data-icon]");
    computePosition(reference || this.element, this.tooltipTarget, {
      placement: this.placementValue,
      middleware: [
        offset({
          mainAxis: this.offsetValue,
          crossAxis: this.crossAxisValue,
        }),
        flip(),
        shift({ padding: 5 }),
      ],
    }).then(({ x, y }) => {
      Object.assign(this.tooltipTarget.style, {
        left: `${x}px`,
        top: `${y}px`,
      });
    });
  }
}