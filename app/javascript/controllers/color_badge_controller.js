import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="color-badge"
// Used by the transaction merchant form to show a preview of what the avatar will look like
export default class extends Controller {
  static targets = ["name", "badge"];

  connect() {
    this.nameTarget.addEventListener("input", this.handleNameChange);
  }

  disconnect() {
    this.nameTarget.removeEventListener("input", this.handleNameChange);
  }

  handleNameChange = (e) => {
    this.nameTarget.textContent = e.currentTarget.value || "?";
  };

  handleColorChange(e) {
    const color = e.currentTarget.value;
    this.badgeTarget.style.backgroundColor = `color-mix(in oklab, ${color} 10%, transparent)`;
    this.badgeTarget.style.borderColor = `color-mix(in oklab, ${color} 10%, transparent)`;
    this.badgeTarget.style.color = color;
  }
}
