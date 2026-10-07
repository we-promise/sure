import { Controller } from "@hotwired/stimulus";

const FOCUSABLE_SELECTOR = [
  "a[href]",
  "button:not([disabled])",
  "textarea:not([disabled])",
  "input:not([disabled]):not([type=hidden])",
  "select:not([disabled])",
  "[tabindex]:not([tabindex='-1'])",
].join(", ");

// Where focus goes back to, left by a dialog replaced while still open for the
// one that takes its place in the same frame.
const returnFocusByFrame = new WeakMap();

// Connects to data-controller="dialog"
export default class extends Controller {
  static targets = ["content"]

  static values = {
    autoOpen: { type: Boolean, default: false },
    reloadOnClose: { type: Boolean, default: false },
    disableClickOutside: { type: Boolean, default: false },
  };

  connect() {
    this._priorFocus = null;
    this._frame = this.element.closest("turbo-frame");
    this._onKeydown = this.#onKeydown.bind(this);
    this._onClose = this.#onClose.bind(this);

    this.element.addEventListener("keydown", this._onKeydown);
    this.element.addEventListener("close", this._onClose);

    if (this.element.matches(":modal")) return;
    // Back restores a dialog cached open as a plain open one: no backdrop, no
    // focus trap. Put it back as it was rendered, closed and with no close
    // event for listeners to act on, and let auto-open show it as a modal.
    if (this.element.open) this.element.removeAttribute("open");
    if (this.autoOpenValue) {
      this._priorFocus = this.#returnFocusTarget();
      this.element.showModal();
      this.#focusInitial();
    }
  }

  disconnect() {
    this.element.removeEventListener("keydown", this._onKeydown);
    this.element.removeEventListener("close", this._onClose);

    // Replaced while still open: one drawer linking to the next inside the
    // same frame. The link that did it left with this dialog, so focus would
    // fall to <body> on close. The dialog connecting in its place, in this
    // same mutation batch, inherits the way back instead.
    if (this._priorFocus && this._frame) {
      const frame = this._frame;
      returnFocusByFrame.set(frame, this._priorFocus);
      queueMicrotask(() => returnFocusByFrame.delete(frame));
    }
  }

  // If the user clicks anywhere outside of the visible content, close the dialog
  clickOutside(e) {
    if (this.disableClickOutsideValue) return;
    if (!this.contentTarget.contains(e.target)) {
      this.close();
    }
  }

  close() {
    this.element.close();
    // Now as well as on the close event: a reload-on-close visit can cache
    // the page before that event fires.
    this.#clearParentModalFrame();

    if (this.reloadOnCloseValue) {
      Turbo.visit(window.location.href);
    }
  }

  // Whatever had focus as this opened, unless that went with the dialog this
  // one replaced.
  #returnFocusTarget() {
    const active = document.activeElement;
    if (active && active !== document.body) return active;
    return returnFocusByFrame.get(this._frame) ?? active;
  }

  // Move focus to the first focusable child unless the dialog already
  // declared one via the autofocus attribute. Native `<dialog>.showModal()`
  // is supposed to do this but the behavior varies across engines.
  #focusInitial() {
    if (this.element.querySelector("[autofocus]")) return;
    this.#focusables()[0]?.focus();
  }

  // Tab/Shift+Tab wrap inside the dialog so focus can't leak to the page
  // behind. Without this an a11y user can tab into the backdrop'd content
  // and lose the modal context entirely.
  #onKeydown(e) {
    if (e.key !== "Tab") return;
    const focusables = this.#focusables();
    if (focusables.length === 0) {
      e.preventDefault();
      return;
    }
    const first = focusables[0];
    const last = focusables[focusables.length - 1];
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  }

  #onClose() {
    const prior = this._priorFocus;
    this._priorFocus = null;
    if (prior && typeof prior.focus === "function" && document.body.contains(prior)) {
      prior.focus();
    }
    // Escape closes the dialog natively, without close().
    this.#clearParentModalFrame();
  }

  #focusables() {
    return Array.from(this.element.querySelectorAll(FOCUSABLE_SELECTOR)).filter(
      (el) => el.offsetParent !== null || el === document.activeElement,
    );
  }

  // When the dialog lives inside a top-level <turbo-frame id="modal">,
  // emptying the frame on close stops Turbo's page cache from snapshotting
  // an open dialog and reopening it on browser back.
  #clearParentModalFrame() {
    const frame = this.element.closest('turbo-frame[id="modal"]');
    if (frame) frame.innerHTML = "";
  }
}
