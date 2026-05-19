import {
  autoUpdate,
  computePosition,
  flip,
  offset,
  shift,
} from "@floating-ui/dom";
import { Controller } from "@hotwired/stimulus";

/**
 * Positioned panel for mixed content (forms, pickers, account menus).
 * Mirrors DS--menu's positioning + open/close lifecycle but skips the
 * `role="menu"` / arrow-key navigation that's specific to action lists.
 * Wiring `aria-expanded` on the trigger so AT users hear "expanded" /
 * "collapsed" as the panel opens / closes.
 */
export default class extends Controller {
  static targets = ["button", "content"];

  static values = {
    show: Boolean,
    placement: { type: String, default: "bottom-end" },
    offset: { type: Number, default: 6 },
    mobileFullwidth: { type: Boolean, default: true },
  };

  connect() {
    this.show = this.showValue;
    this.boundUpdate = this.update.bind(this);
    this.addEventListeners();
    this.startAutoUpdate();
  }

  disconnect() {
    this.removeEventListeners();
    this.stopAutoUpdate();
    this.close();
  }

  addEventListeners() {
    this.buttonTarget.addEventListener("click", this.toggle);
    this.element.addEventListener("keydown", this.handleKeydown);
    document.addEventListener("click", this.handleOutsideClick);
    document.addEventListener("turbo:load", this.handleTurboLoad);
  }

  removeEventListeners() {
    this.buttonTarget.removeEventListener("click", this.toggle);
    this.element.removeEventListener("keydown", this.handleKeydown);
    document.removeEventListener("click", this.handleOutsideClick);
    document.removeEventListener("turbo:load", this.handleTurboLoad);
  }

  handleTurboLoad = () => {
    if (!this.show) this.close();
  };

  handleOutsideClick = (event) => {
    if (this.show && !this.element.contains(event.target)) this.close();
  };

  handleKeydown = (event) => {
    if (event.key === "Escape") {
      this.close();
      this.buttonTarget.focus();
    }
  };

  toggle = () => {
    this.show = !this.show;
    this.contentTarget.classList.toggle("hidden", !this.show);
    this.buttonTarget.setAttribute("aria-expanded", this.show.toString());
    if (this.show) {
      this.update();
      this.focusFirstElement();
    }
  };

  close() {
    this.show = false;
    this.contentTarget.classList.add("hidden");
    this.buttonTarget.setAttribute("aria-expanded", "false");
  }

  focusFirstElement() {
    const focusableElements =
      'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])';
    const firstFocusableElement =
      this.contentTarget.querySelectorAll(focusableElements)[0];
    if (firstFocusableElement) {
      firstFocusableElement.focus({ preventScroll: true });
    }
  }

  startAutoUpdate() {
    if (!this._cleanup) {
      this._cleanup = autoUpdate(
        this.buttonTarget,
        this.contentTarget,
        this.boundUpdate,
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
    if (!this.buttonTarget || !this.contentTarget) return;

    const isSmallScreen = !window.matchMedia("(min-width: 768px)").matches;
    const useMobileFullwidth = isSmallScreen && this.mobileFullwidthValue;

    computePosition(this.buttonTarget, this.contentTarget, {
      placement: useMobileFullwidth ? "bottom" : this.placementValue,
      middleware: [offset(this.offsetValue), flip({ padding: 5 }), shift({ padding: 5 })],
      strategy: "fixed",
    }).then(({ x, y }) => {
      if (useMobileFullwidth) {
        Object.assign(this.contentTarget.style, {
          position: "fixed",
          left: "0px",
          width: "100vw",
          top: `${y}px`,
        });
      } else {
        Object.assign(this.contentTarget.style, {
          position: "fixed",
          left: `${x}px`,
          top: `${y}px`,
          width: "",
        });
      }
    });
  }
}
