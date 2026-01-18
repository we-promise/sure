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

    if (this.hasInitialClass && this.hasVisibleClass) {
      requestAnimationFrame(() => {
        this.element.classList.remove(...this.initialClasses);
        this.element.classList.add(...this.visibleClasses);
      });
    }
  }

  remove() {
    if (this.isRemoving) return;
    this.isRemoving = true;

    if (this.hasVisibleClass && this.hasExitClass) {
      this.element.classList.remove(...this.visibleClasses);
      this.element.classList.add(...this.exitClasses);

      setTimeout(() => {
        this.element.remove();
      }, this.durationValue);
    } else {
      this.element.remove();
    }
  }
}
