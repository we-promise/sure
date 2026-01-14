import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="element-removal"
export default class extends Controller {
  static ANIMATION_DURATION = 300;

  connect() {
    this.isRemoving = false;

    // Trigger fade-in animation
    requestAnimationFrame(() => {
      this.element.classList.remove("opacity-0", "translate-y-[-8px]");
      this.element.classList.add("opacity-100", "translate-y-0");
    });
  }

  remove() {
    if (this.isRemoving) return;
    this.isRemoving = true;

    // Trigger fade-out animation
    this.element.classList.remove("opacity-100", "translate-y-0");
    this.element.classList.add("opacity-0", "translate-y-[-8px]");
    
    // Wait for animation to complete before removing
    setTimeout(() => {
      this.element.remove();
    }, this.constructor.ANIMATION_DURATION);
  }
}
