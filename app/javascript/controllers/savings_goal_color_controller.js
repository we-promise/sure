import { Controller } from "@hotwired/stimulus";

// Updates a colored avatar preview when the user picks a color radio.
// Mirrors the visual interaction of category_controller.js without the
// icon-picker / Pickr machinery — savings goals are color-only.
export default class extends Controller {
  static targets = ["avatar", "color"];

  connect() {
    this.colorTargets.forEach((radio) => {
      radio.addEventListener("change", () => this.updateAvatar(radio.value));
    });
  }

  updateAvatar(hex) {
    if (!this.hasAvatarTarget) return;
    this.avatarTarget.style.backgroundColor = `color-mix(in oklab, ${hex} 12%, transparent)`;
    this.avatarTarget.style.color = hex;
  }
}
