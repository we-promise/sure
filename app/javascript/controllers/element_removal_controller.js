import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="element-removal"
//
// Provides enter/exit animations for dismissible elements like notifications.
//
// Basic usage (no animation):
//   <div data-controller="element-removal">
//     <button data-action="click->element-removal#remove">Close</button>
//   </div>
//
// With fade-up animation (recommended for notifications):
//   <div data-controller="element-removal"
//        data-element-removal-initial-class="animate-fade-up-initial"
//        data-element-removal-visible-class="animate-fade-up-visible"
//        data-element-removal-exit-class="animate-fade-up-exit"
//        class="transition-enter-exit animate-fade-up-initial">
//     Content auto-fades in on connect, fades out on remove
//   </div>
//
// Available animation presets (from animation-utils.css):
//   - animate-fade-up-*: Fade + translate up (notifications, toasts)
//   - animate-fade-*: Simple fade (overlays)
//   - animate-scale-*: Scale + fade (modals, popovers)
//
// The controller:
// 1. On connect: swaps initial -> visible classes (fade in)
// 2. On remove(): swaps visible -> exit classes, waits for transition, removes element
//
export default class extends Controller {
  static values = {
    duration: { type: Number, default: 300 },
  };

  static classes = ["initial", "visible", "exit"];

  connect() {
    this.isRemoving = false;
    this.isVisible = false;
    this._transitionEndHandler = null;
    this._animationEndHandler = null;

    if (this.hasInitialClass && this.hasVisibleClass) {
      // Don't start enter animation if element is in exit state
      const hasExitClasses = this.hasExitClass && this.exitClasses.some(cls => this.element.classList.contains(cls));
      if (hasExitClasses) return;

      requestAnimationFrame(() => {
        if (!this.element) return;
        this.element.classList.remove(...this.initialClasses);
        this.element.classList.add(...this.visibleClasses);
        this.isVisible = true;
      });
    }
  }

  disconnect() {
    this.isRemoving = false;
    this.isVisible = false;
    if (this._removalTimeoutId) {
      clearTimeout(this._removalTimeoutId);
      this._removalTimeoutId = null;
    }
    // Clean up event listeners if they exist
    if (this._transitionEndHandler && this.element) {
      this.element.removeEventListener("transitionend", this._transitionEndHandler);
      this._transitionEndHandler = null;
    }
    if (this._animationEndHandler && this.element) {
      this.element.removeEventListener("animationend", this._animationEndHandler);
      this._animationEndHandler = null;
    }
  }

  remove() {
    if (this.isRemoving) return;
    this.isRemoving = true;

    if (this.hasVisibleClass && this.hasExitClass) {
      this.element.classList.remove(...this.visibleClasses);
      this.element.classList.add(...this.exitClasses);

      const removeElement = () => {
        if (!this.element) return;
        // Event listeners are auto-removed with {once: true}, but clear references
        this._transitionEndHandler = null;
        this._animationEndHandler = null;
        if (this._removalTimeoutId) {
          clearTimeout(this._removalTimeoutId);
          this._removalTimeoutId = null;
        }
        if (this.element.parentNode) {
          this.element.remove();
        }
      };

      const onTransitionEnd = (event) => {
        if (event.target !== this.element) return;
        this._transitionEndHandler = null;
        this._animationEndHandler = null;
        removeElement();
      };

      this._transitionEndHandler = onTransitionEnd;
      this._animationEndHandler = onTransitionEnd;
      this.element.addEventListener("transitionend", onTransitionEnd, { once: true });
      this.element.addEventListener("animationend", onTransitionEnd, { once: true });

      // Fallback timeout in case events don't fire
      this._removalTimeoutId = window.setTimeout(() => {
        removeElement();
      }, this.durationValue + 100);
    } else {
      this.element.remove();
    }
  }
}
