import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="element-removal"
export default class extends Controller {
  connect() {
    // Trigger fade-in animation
    requestAnimationFrame(() => {
      this.element.classList.remove("opacity-0", "translate-y-[-8px]");
      this.element.classList.add("opacity-100", "translate-y-0");
    });
  }

  remove() {
    // Trigger fade-out animation
    this.element.classList.remove("opacity-100", "translate-y-0");
    this.element.classList.add("opacity-0", "translate-y-[-8px]");
    
    // Wait for animation to complete before removing
    setTimeout(() => {
      this.element.remove();
    }, 300); // Match duration-300
  }
}
