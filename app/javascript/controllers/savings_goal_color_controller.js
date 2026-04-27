import { Controller } from "@hotwired/stimulus";

// Updates a colored avatar preview when the user picks a color radio.
// Mirrors the visual interaction of category_controller.js without the
// icon-picker / Pickr machinery: savings goals are color-only.
//
// Wired declaratively from the form template via
//   data-action="change->savings-goal-color#updateAvatar"
// on each radio input, so the controller stays focused on DOM updates
// and avoids double-binding on Turbo reconnect.
export default class extends Controller {
  static targets = ["avatar", "color"];

  updateAvatar(event) {
    if (!this.hasAvatarTarget) return;
    const hex = event.target.value;
    this.avatarTarget.style.backgroundColor = `color-mix(in oklab, ${hex} 12%, transparent)`;
    this.avatarTarget.style.color = hex;
  }
}
