import {
  autoUpdate,
  computePosition,
  flip,
  offset,
  shift,
} from "@floating-ui/dom";
import { Controller } from "@hotwired/stimulus";

/**
 * Strict action-list menu. Container is `role="menu"`, items are
 * `role="menuitem"`. Arrow Up/Down moves focus between items, Home/End
 * jumps to first/last, Escape closes the menu and returns focus to the
 * trigger. Use DS::Popover for mixed-content panels (forms, pickers).
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
      return;
    }
    if (!this.show) return;

    const items = this.#menuItems();
    if (items.length === 0) return;
    const currentIndex = items.indexOf(event.target);

    // Activate the focused item on Enter / Space (ARIA menu pattern).
    // Without this, link-based menuitems can't be activated by keyboard
    // once focus has moved off the native default.
    if (event.key === "Enter" || event.key === " ") {
      if (currentIndex < 0) return;
      event.preventDefault();
      items[currentIndex].click();
      return;
    }

    let nextIndex = null;
    switch (event.key) {
      case "ArrowDown":
        nextIndex = currentIndex < 0 ? 0 : (currentIndex + 1) % items.length;
        break;
      case "ArrowUp":
        nextIndex = currentIndex < 0 ? items.length - 1 : (currentIndex - 1 + items.length) % items.length;
        break;
      case "Home":
        nextIndex = 0;
        break;
      case "End":
        nextIndex = items.length - 1;
        break;
      default:
        return;
    }
    event.preventDefault();
    items.forEach((item, i) => item.setAttribute("tabindex", i === nextIndex ? "0" : "-1"));
    items[nextIndex].focus();
  };

  toggle = () => {
    this.show = !this.show;
    this.contentTarget.classList.toggle("hidden", !this.show);
    this.buttonTarget.setAttribute("aria-expanded", this.show.toString());
    if (this.show) {
      this.update();
      this.#focusFirstMenuItem();
    }
  };

  close() {
    this.show = false;
    this.contentTarget.classList.add("hidden");
    this.buttonTarget.setAttribute("aria-expanded", "false");
  }

  #menuItems() {
    // Include selectable roles (menuitemradio/menuitemcheckbox) so roving focus
    // and keyboard handling work for single/multi-select menus, not just plain
    // action items.
    return Array.from(
      this.contentTarget.querySelectorAll(
        '[role="menuitem"], [role="menuitemradio"], [role="menuitemcheckbox"]',
      ),
    );
  }

  #focusFirstMenuItem() {
    const items = this.#menuItems();
    if (items.length === 0) return;
    items.forEach((item, i) => item.setAttribute("tabindex", i === 0 ? "0" : "-1"));
    items[0].focus({ preventScroll: true });
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
